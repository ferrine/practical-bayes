#!/usr/bin/env bash
#
# Launch the course JupyterHub VM.
#
#   ./lab/launch.sh                       # 127.0.0.1:8000, 256 GiB, 24 vCPU
#   ./lab/launch.sh --host 0.0.0.0        # publish to the network (HTTP!)
#   ./lab/launch.sh --admin ferrine       # who can approve signups
#
# Disks are created on first run under lab/state/ and reused afterwards:
#   root.qcow2  disposable OS disk -- delete it to reset the machine
#   data.qcow2  /var/lib -- hub database (accounts) + every student home
#
# Everything is passed through to nix-build, so there is a single source of
# truth for the configuration. The cost is a NixOS evaluation (~30 s) per
# launch; the closure itself is cached after the first build.
set -euo pipefail

LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ---------------------------------------------------------------- defaults
HOST=${LAB_HOST:-127.0.0.1}      # host interface the hub is published on
PORT=${LAB_PORT:-8000}           # host port
MEM_GIB=${LAB_MEM:-256}          # guest RAM, GiB
CPUS=${LAB_CPUS:-24}             # guest vCPUs
DATA_SIZE=${LAB_DATA_SIZE:-200G} # persistent disk, created once
ROOT_GIB=${LAB_ROOT_SIZE:-20}    # disposable OS disk, GiB
STATE=${LAB_STATE:-$LAB_DIR/state}
ADMINS=${LAB_ADMINS:-${USER:-admin}}
PER_USER_MEM=${LAB_PER_USER_MEM:-16G}
PER_USER_CPUS=${LAB_PER_USER_CPUS:-4}
IDLE_TIMEOUT=${LAB_IDLE_TIMEOUT:-7200}
SSH_PORT=${LAB_SSH_PORT:-}
SSH_KEY=${LAB_SSH_KEY:-}
BUILD_ONLY=0
DETACH=0

# Extra flags for every nix-build below, word-split on purpose. Useful when the
# machine's configured substituters are unreachable or slow -- see lab/README.md.
read -r -a NIX_OPTS <<<"${LAB_NIX_OPTS:-}"

usage() {
  sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options (each also settable as LAB_<NAME>):

  --host ADDR          host interface to publish on   [$HOST]
  --port N             host port                      [$PORT]
  --mem GIB            guest RAM in GiB               [$MEM_GIB]
  --cpus N             guest vCPUs                    [$CPUS]
  --admin NAME[,NAME]  JupyterHub admins              [$ADMINS]
  --per-user-mem SIZE  RAM cap per student            [$PER_USER_MEM]
  --per-user-cpus N    CPU cap per student            [$PER_USER_CPUS]
  --idle-timeout SEC   cull idle servers after        [$IDLE_TIMEOUT]
  --data-size SIZE     persistent disk (first run)    [$DATA_SIZE]
  --root-size GIB      disposable OS disk             [$ROOT_GIB]
  --state DIR          where the disk images live     [$STATE]
  --ssh-port N         forward 127.0.0.1:N to guest sshd
  --ssh-key PATH       authorized_keys file for root in the guest
  --build-only         build the VM but do not start it
  --detach             run in the background, survives this shell
  -h, --help           this message

With --detach the VM is disowned from this terminal and leaves three files in
the state directory:

  lab-vm.pid           qemu's pid
  lab-vm.log           the guest console
  qemu-monitor.sock    QEMU monitor -- the graceful way to stop a detached VM:

      echo system_powerdown | socat - UNIX-CONNECT:$STATE/qemu-monitor.sock

  Killing the pid instead is the equivalent of yanking the power cord.
EOF
}

die() {
  echo "launch.sh: $*" >&2
  exit 1
}

# ------------------------------------------------------------------- flags
while [ $# -gt 0 ]; do
  case "$1" in
  --host) HOST=$2; shift 2 ;;
  --port) PORT=$2; shift 2 ;;
  --mem) MEM_GIB=$2; shift 2 ;;
  --cpus) CPUS=$2; shift 2 ;;
  --admin | --admins) ADMINS=$2; shift 2 ;;
  --per-user-mem) PER_USER_MEM=$2; shift 2 ;;
  --per-user-cpus) PER_USER_CPUS=$2; shift 2 ;;
  --idle-timeout) IDLE_TIMEOUT=$2; shift 2 ;;
  --data-size) DATA_SIZE=$2; shift 2 ;;
  --root-size) ROOT_GIB=$2; shift 2 ;;
  --state) STATE=$2; shift 2 ;;
  --ssh-port) SSH_PORT=$2; shift 2 ;;
  --ssh-key) SSH_KEY=$2; shift 2 ;;
  --build-only) BUILD_ONLY=1; shift ;;
  --detach) DETACH=1; shift ;;
  -h | --help) usage; exit 0 ;;
  *) die "unknown option '$1' (try --help)" ;;
  esac
done

[ -e /dev/kvm ] || die "/dev/kvm is missing -- the VM would be unusably slow"

SSH_KEYS=""
if [ -n "$SSH_KEY" ]; then
  [ -r "$SSH_KEY" ] || die "cannot read ssh key file '$SSH_KEY'"
  SSH_KEYS=$(cat "$SSH_KEY")
fi

mkdir -p "$STATE"
STATE=$(cd "$STATE" && pwd)
ROOT_IMG="$STATE/root.qcow2"
DATA_IMG="$STATE/data.qcow2"

# -------------------------------------------------------------------- build
echo ">>> building the lab VM (this evaluates NixOS; first run also downloads"
echo "    the PyMC/JAX closure and takes a while)"
nix-build "$LAB_DIR" -A vm -o "$STATE/vm" \
  ${NIX_OPTS[@]+"${NIX_OPTS[@]}"} \
  --argstr hostAddress "$HOST" \
  --argstr hostPort "$PORT" \
  --argstr memoryMiB "$((MEM_GIB * 1024))" \
  --argstr cores "$CPUS" \
  --argstr rootDiskMiB "$((ROOT_GIB * 1024))" \
  --argstr sshPort "$SSH_PORT" \
  --argstr admins "$ADMINS" \
  --argstr perUserMemory "$PER_USER_MEM" \
  --argstr perUserCpus "$PER_USER_CPUS" \
  --argstr idleTimeout "$IDLE_TIMEOUT" \
  --argstr sshKeys "$SSH_KEYS"

runner=$(echo "$STATE"/vm/bin/run-*-vm)
[ -x "$runner" ] || die "no VM runner at $STATE/vm/bin"

# ------------------------------------------------------------ persistent disk
# The root image creates itself on first boot; the data image has to carry a
# filesystem before the guest can mount it, so build it here the same way the
# NixOS VM runner builds its own root image.
if [ ! -e "$DATA_IMG" ]; then
  echo ">>> creating the persistent data disk ($DATA_SIZE) at $DATA_IMG"
  qemu=$(nix-build "$LAB_DIR" -A qemu_kvm --no-out-link ${NIX_OPTS[@]+"${NIX_OPTS[@]}"})
  e2fs=$(nix-build "$LAB_DIR" -A e2fsprogs --no-out-link ${NIX_OPTS[@]+"${NIX_OPTS[@]}"})
  raw=$(mktemp "$STATE/.data-XXXXXX.raw")
  trap 'rm -f "$raw"' EXIT
  "$qemu/bin/qemu-img" create -f raw -q "$raw" "$DATA_SIZE"
  "$e2fs/bin/mkfs.ext4" -q -L labdata "$raw"
  "$qemu/bin/qemu-img" convert -f raw -O qcow2 "$raw" "$DATA_IMG"
  rm -f "$raw"
  trap - EXIT
fi

if [ "$BUILD_ONLY" = 1 ]; then
  echo ">>> built: $runner"
  exit 0
fi

# --------------------------------------------------------------------- run
PIDFILE="$STATE/lab-vm.pid"
VMLOG="$STATE/lab-vm.log"
MONITOR="$STATE/qemu-monitor.sock"

if [ -e "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  die "a VM from this state directory is already running (pid $(cat "$PIDFILE"), $PIDFILE)"
fi

cat <<EOF

    JupyterHub   http://$HOST:$PORT/
    signup       http://$HOST:$PORT/hub/signup
    approvals    http://$HOST:$PORT/hub/authorize   (admins: $ADMINS)
    per student  $PER_USER_MEM RAM / $PER_USER_CPUS CPU, idle cull after ${IDLE_TIMEOUT}s
    guest        ${MEM_GIB} GiB RAM / $CPUS vCPU
    persistent   $DATA_IMG  (mounted at /var/lib)
$([ -n "$SSH_PORT" ] && echo "    ssh          ssh -p $SSH_PORT root@127.0.0.1")
EOF

export NIX_DISK_IMAGE="$ROOT_IMG"
export LAB_DATA_IMAGE="$DATA_IMG"

if [ "$DETACH" = 1 ]; then
  # A monitor socket is the only graceful way to shut down a VM whose console
  # nobody is holding.
  # -pidfile makes QEMU record its *own* pid (the runner script is only its
  # parent) and remove the file when it exits, so the check above is reliable.
  export QEMU_OPTS="${QEMU_OPTS:-} -monitor unix:$MONITOR,server,nowait -pidfile $PIDFILE"
  rm -f "$MONITOR" "$PIDFILE"
  setsid "$runner" >"$VMLOG" 2>&1 </dev/null &
  runner_pid=$!
  for _ in $(seq 1 120); do
    [ -s "$PIDFILE" ] && break
    kill -0 "$runner_pid" 2>/dev/null || die "the VM exited immediately; see $VMLOG"
    sleep 0.5
  done
  [ -s "$PIDFILE" ] || die "QEMU did not write $PIDFILE; see $VMLOG"
  cat <<EOF
    pid          $(cat "$PIDFILE")   ($PIDFILE)
    console log  $VMLOG
    stop         echo system_powerdown | socat - UNIX-CONNECT:$MONITOR

    Detached. It keeps running after this shell exits.

EOF
  exit 0
fi

cat <<EOF

    The VM console is attached to this terminal; type 'poweroff' there to stop
    it cleanly. Use --detach to run it in the background instead.

EOF
exec "$runner"
