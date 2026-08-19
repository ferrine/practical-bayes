# QEMU side of the lab VM: resources, disks, port forwarding.
#
# Two disks:
#   * the root image (NIX_DISK_IMAGE) is disposable -- the Nix store comes from
#     the host over 9p, so it only holds /etc, /var/log and the like. Delete it
#     to reset the machine.
#   * the data image (LAB_DATA_IMAGE) is mounted at /var/lib and holds
#     everything that must survive: the hub database (accounts, password
#     hashes, approvals) under /var/lib/jupyterhub, and every student home
#     under /var/lib/private/<name>.
{ lib, labCfg, ... }:

{
  virtualisation = {
    memorySize = labCfg.memoryMiB;
    cores = labCfg.cores;

    # Headless: the console lands in the terminal that ran ./launch.sh.
    graphics = false;

    # Bigger 9p packets -- the whole Nix store is mounted from the host.
    msize = 131072;

    diskSize = labCfg.rootDiskMiB;

    forwardPorts = [
      {
        from = "host";
        host = {
          address = labCfg.hostAddress;
          port = labCfg.hostPort;
        };
        guest.port = labCfg.hubPort;
      }
    ] ++ lib.optional (labCfg.sshPort != null) {
      from = "host";
      host = {
        address = "127.0.0.1";
        port = labCfg.sshPort;
      };
      guest.port = 22;
    };

    # The persistent data disk. Identified by serial rather than by drive
    # order, so it stays /dev/disk/by-id/virtio-labdata whatever else changes.
    qemu.drives = [
      {
        name = "labdata";
        file = ''"$LAB_DATA_IMAGE"'';
        deviceExtraOpts.serial = "labdata";
        driveExtraOpts = {
          werror = "report";
          cache = "writeback";
        };
      }
    ];

    fileSystems."/var/lib" = {
      device = "/dev/disk/by-id/virtio-labdata";
      fsType = "ext4";
      # launch.sh already puts an ext4 filesystem in the image; this is a
      # belt-and-braces fallback for a hand-created disk. Mounted in stage 2
      # (systemd handles x-systemd.makefs there), which is early enough:
      # systemd orders StateDirectory= units after the /var/lib mount.
      autoFormat = true;
    };
  };
}
