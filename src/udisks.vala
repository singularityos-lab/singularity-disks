namespace Singularity.Apps.Disks {

    public const string UDISKS = "org.freedesktop.UDisks2";
    public const string IFACE_DRIVE = "org.freedesktop.UDisks2.Drive";
    public const string IFACE_ATA = "org.freedesktop.UDisks2.Drive.Ata";
    public const string IFACE_NVME = "org.freedesktop.UDisks2.NVMe.Controller";
    public const string IFACE_BLOCK = "org.freedesktop.UDisks2.Block";
    public const string IFACE_TABLE = "org.freedesktop.UDisks2.PartitionTable";
    public const string IFACE_PARTITION = "org.freedesktop.UDisks2.Partition";
    public const string IFACE_FILESYSTEM = "org.freedesktop.UDisks2.Filesystem";
    public const string IFACE_ENCRYPTED = "org.freedesktop.UDisks2.Encrypted";
    public const string IFACE_LOOP = "org.freedesktop.UDisks2.Loop";
    public const string IFACE_SWAP = "org.freedesktop.UDisks2.Swapspace";
    public const string IFACE_JOB = "org.freedesktop.UDisks2.Job";
    public const string IFACE_MANAGER = "org.freedesktop.UDisks2.Manager";

    public class UObject : Object {
        public DBusObject object;
        public string path;

        public UObject (DBusObject object) {
            this.object = object;
            this.path = object.get_object_path ();
        }

        public DBusProxy? iface (string name) {
            return object.get_interface (name) as DBusProxy;
        }

        public bool has (string name) {
            return object.get_interface (name) != null;
        }

        public Variant? prop (string iface_name, string property) {
            var proxy = iface (iface_name);
            return proxy != null ? proxy.get_cached_property (property) : null;
        }

        public string str (string iface_name, string property) {
            var v = prop (iface_name, property);
            if (v == null) return "";
            if (v.is_of_type (VariantType.STRING) || v.is_of_type (VariantType.OBJECT_PATH)) return v.get_string ();
            if (v.is_of_type (VariantType.BYTESTRING)) return bytestring (v);
            return "";
        }

        public uint64 u64 (string iface_name, string property) {
            var v = prop (iface_name, property);
            if (v == null) return 0;
            if (v.is_of_type (VariantType.UINT64)) return v.get_uint64 ();
            if (v.is_of_type (VariantType.INT64)) return (uint64) v.get_int64 ();
            if (v.is_of_type (VariantType.UINT32)) return v.get_uint32 ();
            if (v.is_of_type (VariantType.INT32)) return (uint64) v.get_int32 ();
            return 0;
        }

        public int64 i64 (string iface_name, string property) {
            var v = prop (iface_name, property);
            if (v == null) return 0;
            if (v.is_of_type (VariantType.INT64)) return v.get_int64 ();
            if (v.is_of_type (VariantType.UINT64)) return (int64) v.get_uint64 ();
            if (v.is_of_type (VariantType.INT32)) return v.get_int32 ();
            if (v.is_of_type (VariantType.UINT32)) return v.get_uint32 ();
            return 0;
        }

        public double dbl (string iface_name, string property) {
            var v = prop (iface_name, property);
            return v != null && v.is_of_type (VariantType.DOUBLE) ? v.get_double () : 0;
        }

        public bool flag (string iface_name, string property) {
            var v = prop (iface_name, property);
            return v != null && v.is_of_type (VariantType.BOOLEAN) && v.get_boolean ();
        }

        public static string bytestring (Variant v) {
            if (v.is_of_type (VariantType.BYTESTRING)) return v.get_bytestring ();
            var builder = new StringBuilder ();
            for (size_t i = 0; i < v.n_children (); i++) {
                uint8 c = v.get_child_value (i).get_byte ();
                if (c == 0) break;
                builder.append_c ((char) c);
            }
            return builder.str;
        }

        public string[] mount_points () {
            string[] result = {};
            var v = prop (IFACE_FILESYSTEM, "MountPoints");
            if (v == null) return result;
            for (size_t i = 0; i < v.n_children (); i++) result += bytestring (v.get_child_value (i));
            return result;
        }

        public string device () {
            string preferred = str (IFACE_BLOCK, "PreferredDevice");
            return preferred != "" ? preferred : str (IFACE_BLOCK, "Device");
        }

        public async Variant call (string iface_name, string method, Variant? parameters, int timeout = -1) throws Error {
            var proxy = iface (iface_name);
            if (proxy == null) throw new IOError.NOT_SUPPORTED ("%s is not available", iface_name);
            return yield proxy.call (method, parameters, DBusCallFlags.NONE, timeout, null);
        }

        public async Variant call_with_fd (string iface_name, string method, Variant? parameters, out UnixFDList? out_fds) throws Error {
            var proxy = iface (iface_name);
            if (proxy == null) throw new IOError.NOT_SUPPORTED ("%s is not available", iface_name);
            return yield proxy.call_with_unix_fd_list (method, parameters, DBusCallFlags.NONE, -1, null, null, out out_fds);
        }
    }

    public class Segment : Object {
        public UObject? block;
        public uint64 offset;
        public uint64 size;
        public bool free;
        public bool extended;
        public bool logical;

        public Segment (UObject? block, uint64 offset, uint64 size) {
            this.block = block;
            this.offset = offset;
            this.size = size;
            this.free = block == null;
        }
    }

    public static Variant empty_options () {
        return new Variant.array (new VariantType ("{sv}"), {});
    }

    public static Variant options (string[] keys, Variant[] values) {
        var builder = new VariantBuilder (new VariantType ("a{sv}"));
        for (int i = 0; i < keys.length; i++) builder.add ("{sv}", keys[i], values[i]);
        return builder.end ();
    }

    public class UDisksClient : Object {
        private const uint64 ALIGNMENT = 1024 * 1024;
        private DBusObjectManagerClient manager;
        private Gee.HashMap<string, UObject> objects = new Gee.HashMap<string, UObject> ();
        private uint changed_source = 0;

        public signal void changed ();

        public static async UDisksClient create () throws Error {
            var client = new UDisksClient ();
            client.manager = yield new DBusObjectManagerClient.for_bus (BusType.SYSTEM,
                DBusObjectManagerClientFlags.NONE, UDISKS, "/org/freedesktop/UDisks2", null, null);
            client.manager.object_added.connect (() => client.queue_changed ());
            client.manager.object_removed.connect (() => client.queue_changed ());
            client.manager.interface_added.connect (() => client.queue_changed ());
            client.manager.interface_removed.connect (() => client.queue_changed ());
            client.manager.interface_proxy_properties_changed.connect (() => client.queue_changed ());
            return client;
        }

        private void queue_changed () {
            if (changed_source != 0) return;
            changed_source = Timeout.add (120, () => {
                changed_source = 0;
                changed ();
                return Source.REMOVE;
            });
        }

        public UObject? lookup (string? path) {
            if (path == null || path == "" || path == "/") return null;
            var existing = objects[path];
            var dbus_object = manager.get_object (path);
            if (dbus_object == null) return null;
            if (existing != null && existing.object == dbus_object) return existing;
            var wrapped = new UObject (dbus_object);
            objects[path] = wrapped;
            return wrapped;
        }

        public Gee.List<UObject> all () {
            var list = new Gee.ArrayList<UObject> ();
            foreach (var o in manager.get_objects ()) {
                var wrapped = lookup (o.get_object_path ());
                if (wrapped != null) list.add (wrapped);
            }
            return list;
        }

        public Gee.List<UObject> drives () {
            var list = new Gee.ArrayList<UObject> ();
            foreach (var o in all ()) if (o.has (IFACE_DRIVE)) list.add (o);
            list.sort ((a, b) => strcmp (drive_sort_key (a), drive_sort_key (b)));
            return list;
        }

        private string drive_sort_key (UObject drive) {
            string key = drive.str (IFACE_DRIVE, "SortKey");
            return key != "" ? key : drive.path;
        }

        public Gee.List<UObject> loop_devices () {
            var list = new Gee.ArrayList<UObject> ();
            foreach (var o in all ()) {
                if (!o.has (IFACE_LOOP) || !o.has (IFACE_BLOCK)) continue;
                if (o.u64 (IFACE_BLOCK, "Size") == 0) continue;
                if (o.has (IFACE_PARTITION)) continue;
                list.add (o);
            }
            list.sort ((a, b) => strcmp (a.device (), b.device ()));
            return list;
        }

        public UObject? block_for_drive (UObject drive) {
            foreach (var o in all ()) {
                if (!o.has (IFACE_BLOCK) || o.has (IFACE_PARTITION)) continue;
                if (o.str (IFACE_BLOCK, "Drive") != drive.path) continue;
                if (o.str (IFACE_BLOCK, "CryptoBackingDevice") != "/" && o.str (IFACE_BLOCK, "CryptoBackingDevice") != "") continue;
                return o;
            }
            return null;
        }

        public UObject? drive_for_block (UObject block) {
            return lookup (block.str (IFACE_BLOCK, "Drive"));
        }

        public Gee.List<UObject> partitions (UObject table) {
            var list = new Gee.ArrayList<UObject> ();
            foreach (var o in all ()) {
                if (o.has (IFACE_PARTITION) && o.str (IFACE_PARTITION, "Table") == table.path) list.add (o);
            }
            list.sort ((a, b) => {
                uint64 x = a.u64 (IFACE_PARTITION, "Offset"), y = b.u64 (IFACE_PARTITION, "Offset");
                return x < y ? -1 : (x > y ? 1 : 0);
            });
            return list;
        }

        public UObject? cleartext (UObject encrypted) {
            foreach (var o in all ()) {
                if (o.has (IFACE_BLOCK) && o.str (IFACE_BLOCK, "CryptoBackingDevice") == encrypted.path) return o;
            }
            return null;
        }

        public Gee.List<UObject> jobs_for (UObject target) {
            var list = new Gee.ArrayList<UObject> ();
            foreach (var o in all ()) {
                if (!o.has (IFACE_JOB)) continue;
                var objs = o.prop (IFACE_JOB, "Objects");
                if (objs == null) continue;
                for (size_t i = 0; i < objs.n_children (); i++) {
                    if (objs.get_child_value (i).get_string () == target.path) {
                        list.add (o);
                        break;
                    }
                }
            }
            return list;
        }

        public Gee.List<Segment> layout (UObject disk_block) {
            var segments = new Gee.ArrayList<Segment> ();
            uint64 disk_size = disk_block.u64 (IFACE_BLOCK, "Size");
            if (!disk_block.has (IFACE_TABLE)) {
                segments.add (new Segment (disk_block, 0, disk_size));
                return segments;
            }
            bool gpt = disk_block.str (IFACE_TABLE, "Type") == "gpt";
            uint64 start = ALIGNMENT;
            uint64 end = disk_size > ALIGNMENT ? disk_size - (gpt ? ALIGNMENT : 0) : disk_size;
            var parts = partitions (disk_block);
            uint64 cursor = start;
            UObject? extended = null;
            foreach (var p in parts) {
                if (p.flag (IFACE_PARTITION, "IsContained")) continue;
                uint64 offset = p.u64 (IFACE_PARTITION, "Offset");
                uint64 size = p.u64 (IFACE_PARTITION, "Size");
                if (offset > cursor && offset - cursor >= ALIGNMENT) segments.add (new Segment (null, cursor, offset - cursor));
                var seg = new Segment (p, offset, size);
                seg.extended = p.flag (IFACE_PARTITION, "IsContainer");
                if (seg.extended) extended = p;
                segments.add (seg);
                cursor = uint64.max (cursor, offset + size);
            }
            if (end > cursor && end - cursor >= ALIGNMENT) segments.add (new Segment (null, cursor, end - cursor));
            if (extended != null) {
                uint64 ext_off = extended.u64 (IFACE_PARTITION, "Offset");
                uint64 ext_end = ext_off + extended.u64 (IFACE_PARTITION, "Size");
                uint64 inner = ext_off + ALIGNMENT;
                var logicals = new Gee.ArrayList<Segment> ();
                foreach (var p in parts) {
                    if (!p.flag (IFACE_PARTITION, "IsContained")) continue;
                    uint64 offset = p.u64 (IFACE_PARTITION, "Offset");
                    uint64 size = p.u64 (IFACE_PARTITION, "Size");
                    if (offset > inner + ALIGNMENT) {
                        var gap = new Segment (null, inner, offset - inner);
                        gap.logical = true;
                        logicals.add (gap);
                    }
                    var seg = new Segment (p, offset, size);
                    seg.logical = true;
                    logicals.add (seg);
                    inner = offset + size;
                }
                if (ext_end > inner + ALIGNMENT) {
                    var gap = new Segment (null, inner, ext_end - inner);
                    gap.logical = true;
                    logicals.add (gap);
                }
                int index = 0;
                for (int i = 0; i < segments.size; i++) if (segments[i].block == extended) index = i;
                for (int i = 0; i < logicals.size; i++) segments.insert (index + 1 + i, logicals[i]);
            }
            return segments;
        }

        public async bool can_format (string type, out string missing) throws Error {
            missing = "";
            var manager_object = lookup ("/org/freedesktop/UDisks2/Manager");
            if (manager_object == null) return true;
            var reply = yield manager_object.call (IFACE_MANAGER, "CanFormat", new Variant ("(s)", type));
            bool ok;
            string util;
            reply.get ("((bs))", out ok, out util);
            missing = util;
            return ok;
        }

        public async string loop_setup (string path, bool read_only) throws Error {
            var manager_object = lookup ("/org/freedesktop/UDisks2/Manager");
            if (manager_object == null) throw new IOError.NOT_SUPPORTED ("UDisks is not available");
            int fd = Posix.open (path, read_only ? Posix.O_RDONLY : Posix.O_RDWR);
            if (fd < 0) throw new IOError.FAILED ("%s", strerror (errno));
            var fds = new UnixFDList ();
            int index = fds.append (fd);
            Posix.close (fd);
            var proxy = manager_object.iface (IFACE_MANAGER);
            UnixFDList? out_fds;
            var reply = yield proxy.call_with_unix_fd_list ("LoopSetup",
                new Variant ("(h@a{sv})", index, options ({ "read-only" }, { new Variant.boolean (read_only) })),
                DBusCallFlags.NONE, -1, fds, null, out out_fds);
            string result;
            reply.get ("(o)", out result);
            return result;
        }
    }
}
