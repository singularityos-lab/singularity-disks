namespace Singularity.Apps.Disks {

    public class Medium : Object {
        public UObject drive;
        public string title = "";
        public string icon_name = "drive-removable-media";
        public string symbolic_icon = "drive-removable-media-symbolic";
        public string mount_point = "";
        public uint64 size;
        public uint64 free;
        public bool has_usage;
        public bool busy;
        public string? error;

        public bool mounted {
            get { return mount_point != ""; }
        }

        public string detail () {
            if (error != null) return error;
            if (busy) return _("Ejecting…");
            if (has_usage) return _("%s free of %s").printf (GLib.format_size (free), GLib.format_size (size));
            if (size > 0) return _("%s, not mounted").printf (GLib.format_size (size));
            return _("Not mounted");
        }

        public double used_fraction () {
            if (!has_usage || size == 0) return 0;
            return ((double) (size - free) / size).clamp (0, 1);
        }
    }

    public class RemovableMonitor : Object {
        private static RemovableMonitor? instance;
        private UDisksClient? client;
        private uint refresh_source;
        private int serial;
        private Gee.HashMap<string, string> errors = new Gee.HashMap<string, string> ();
        private Gee.HashSet<string> ejecting = new Gee.HashSet<string> ();

        public Gee.ArrayList<Medium> media = new Gee.ArrayList<Medium> ();
        public bool available { get; private set; }

        public signal void changed ();

        public static RemovableMonitor get_default () {
            if (instance == null) instance = new RemovableMonitor ();
            return instance;
        }

        private RemovableMonitor () {
            connect_client.begin ();
        }

        private async void connect_client () {
            try {
                client = yield UDisksClient.create ();
            } catch (Error e) {
                warning ("disks: %s", e.message);
                return;
            }
            available = true;
            client.changed.connect (() => refresh.begin ());
            refresh_source = Timeout.add_seconds (30, () => {
                refresh.begin ();
                return Source.CONTINUE;
            });
            yield refresh ();
        }

        public bool any_mounted () {
            foreach (var m in media) if (m.mounted) return true;
            return false;
        }

        private static bool is_removable (UObject drive) {
            if (drive.flag (IFACE_DRIVE, "Removable") || drive.flag (IFACE_DRIVE, "MediaRemovable")) return true;
            string bus = drive.str (IFACE_DRIVE, "ConnectionBus");
            return bus == "usb" || bus == "sdio" || bus == "ieee1394";
        }

        private Gee.List<UObject> volumes (UObject disk) {
            var list = new Gee.ArrayList<UObject> ();
            list.add (disk);
            list.add_all (client.partitions (disk));
            var result = new Gee.ArrayList<UObject> ();
            foreach (var b in list) {
                if (b.has (IFACE_ENCRYPTED)) {
                    var c = client.cleartext (b);
                    if (c != null) result.add (c);
                    else result.add (b);
                } else if (b.has (IFACE_FILESYSTEM)) {
                    result.add (b);
                }
            }
            return result;
        }

        private async void refresh () {
            if (client == null) return;
            int current = ++serial;
            var found = new Gee.ArrayList<Medium> ();
            foreach (var drive in client.drives ()) {
                if (!is_removable (drive)) continue;
                var disk = client.block_for_drive (drive);
                if (disk == null || disk.flag (IFACE_BLOCK, "HintIgnore")) continue;
                var vols = volumes (disk);
                if (vols.size == 0) continue;
                var m = new Medium ();
                m.drive = drive;
                m.busy = ejecting.contains (drive.path);
                m.error = errors[drive.path];
                string label = "";
                foreach (var v in vols) {
                    if (label == "") label = v.str (IFACE_BLOCK, "IdLabel");
                    if (m.mount_point == "" && v.has (IFACE_FILESYSTEM)) {
                        var points = v.mount_points ();
                        if (points.length > 0) m.mount_point = points[0];
                    }
                }
                if (label == "") {
                    string vendor = drive.str (IFACE_DRIVE, "Vendor").strip ();
                    string model = drive.str (IFACE_DRIVE, "Model").strip ();
                    label = (vendor + " " + model).strip ();
                }
                m.title = label != "" ? label : _("Removable Drive");
                m.size = disk.u64 (IFACE_BLOCK, "Size");
                string media_kind = drive.str (IFACE_DRIVE, "Media");
                if (media_kind.has_prefix ("flash_sd") || media_kind.has_prefix ("flash_mmc") || drive.str (IFACE_DRIVE, "ConnectionBus") == "sdio") {
                    m.icon_name = "media-flash";
                    m.symbolic_icon = "media-flash-symbolic";
                } else if (media_kind.has_prefix ("optical")) {
                    m.icon_name = "media-optical";
                    m.symbolic_icon = "media-optical-symbolic";
                }
                if (m.mounted) {
                    try {
                        var info = yield File.new_for_path (m.mount_point).query_filesystem_info_async (
                            FileAttribute.FILESYSTEM_SIZE + "," + FileAttribute.FILESYSTEM_FREE, Priority.DEFAULT, null);
                        uint64 total = info.get_attribute_uint64 (FileAttribute.FILESYSTEM_SIZE);
                        if (total > 0) {
                            m.size = total;
                            m.free = info.get_attribute_uint64 (FileAttribute.FILESYSTEM_FREE);
                            m.has_usage = true;
                        }
                    } catch (Error e) {
                    }
                }
                found.add (m);
            }
            if (current != serial) return;
            media = found;
            changed ();
        }

        public async void eject (Medium m) {
            if (client == null || ejecting.contains (m.drive.path)) return;
            var drive = m.drive;
            ejecting.add (drive.path);
            errors.unset (drive.path);
            yield refresh ();
            try {
                var disk = client.block_for_drive (drive);
                if (disk != null) {
                    var blocks = new Gee.ArrayList<UObject> ();
                    blocks.add (disk);
                    blocks.add_all (client.partitions (disk));
                    foreach (var b in blocks) {
                        if (b.has (IFACE_ENCRYPTED)) {
                            var c = client.cleartext (b);
                            if (c != null) {
                                if (c.has (IFACE_FILESYSTEM) && c.mount_points ().length > 0) yield c.call (IFACE_FILESYSTEM, "Unmount", new Variant ("(@a{sv})", empty_options ()));
                                yield b.call (IFACE_ENCRYPTED, "Lock", new Variant ("(@a{sv})", empty_options ()));
                            }
                        }
                        if (b.has (IFACE_FILESYSTEM) && b.mount_points ().length > 0) yield b.call (IFACE_FILESYSTEM, "Unmount", new Variant ("(@a{sv})", empty_options ()));
                    }
                }
                if (drive.flag (IFACE_DRIVE, "CanPowerOff")) yield drive.call (IFACE_DRIVE, "PowerOff", new Variant ("(@a{sv})", empty_options ()));
                else if (drive.flag (IFACE_DRIVE, "Ejectable")) yield drive.call (IFACE_DRIVE, "Eject", new Variant ("(@a{sv})", empty_options ()));
            } catch (Error e) {
                string remote = DBusError.get_remote_error (e) ?? "";
                if (remote.has_suffix ("DeviceBusy") || e.message.contains ("target is busy")) errors[drive.path] = _("In use, close the files on it first");
                else if (remote.contains ("NotAuthorized")) errors[drive.path] = _("Not allowed");
                else errors[drive.path] = _("Could not eject");
            }
            ejecting.remove (drive.path);
            yield refresh ();
        }
    }
}
