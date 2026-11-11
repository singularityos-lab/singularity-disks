namespace Singularity.Apps.Disks {

    internal class DisksIntents : Object {
        private static UDisksClient? client = null;

        private static string text(Json.Object args, string key) {
            return args.has_member(key) ? args.get_string_member(key).strip() : "";
        }

        private static async UDisksClient udisks() throws Error {
            if (client == null) client = yield UDisksClient.create();
            return client;
        }

        private static bool is_volume(UObject o) {
            if (!o.has(IFACE_BLOCK)) return false;
            if (o.flag(IFACE_BLOCK, "HintIgnore")) return false;
            return o.has(IFACE_FILESYSTEM) || o.has(IFACE_ENCRYPTED) || o.has(IFACE_SWAP);
        }

        private static string volume_name(UObject v) {
            string label = v.str(IFACE_BLOCK, "IdLabel");
            return label != "" ? label : v.device();
        }

        private static UObject find_volume(UDisksClient c, string wanted) throws Error {
            if (wanted == "") throw new IOError.INVALID_ARGUMENT("give the volume device, label or mount point from disks_list");
            string w = wanted.casefold();
            foreach (var o in c.all()) {
                if (!is_volume(o)) continue;
                if (o.device() == wanted || o.path == wanted || o.str(IFACE_BLOCK, "IdLabel").casefold() == w) return o;
                if (o.has(IFACE_FILESYSTEM)) foreach (string m in o.mount_points()) if (m == wanted) return o;
            }
            throw new IOError.NOT_FOUND("no volume %s; see disks_list", wanted);
        }

        private static UObject find_drive(UDisksClient c, string wanted) throws Error {
            if (wanted == "") throw new IOError.INVALID_ARGUMENT("give the drive id or model from disks_list");
            string w = wanted.casefold();
            foreach (var d in c.drives()) {
                var block = c.block_for_drive(d);
                if (d.path == wanted || (block != null && block.device() == wanted)) return d;
                if (d.path.has_suffix("/" + wanted)) return d;
            }
            UObject? hit = null;
            foreach (var d in c.drives()) {
                string model = (d.str(IFACE_DRIVE, "Vendor") + " " + d.str(IFACE_DRIVE, "Model")).strip().casefold();
                if (!model.contains(w)) continue;
                if (hit != null) throw new IOError.INVALID_ARGUMENT("%s matches more than one drive; use the id", wanted);
                hit = d;
            }
            if (hit != null) return hit;
            foreach (var o in c.all()) {
                if (!is_volume(o)) continue;
                if (o.device() == wanted || o.str(IFACE_BLOCK, "IdLabel").casefold() == w) {
                    var d = c.drive_for_block(o);
                    if (d != null) return d;
                }
            }
            throw new IOError.NOT_FOUND("no drive %s; see disks_list", wanted);
        }

        private static string health(UObject d) {
            if (d.has(IFACE_ATA)) {
                if (!d.flag(IFACE_ATA, "SmartSupported") || !d.flag(IFACE_ATA, "SmartEnabled")) return "";
                if (d.flag(IFACE_ATA, "SmartFailing")) return "failing";
                if (d.i64(IFACE_ATA, "SmartNumBadSectors") > 0) return "bad sectors";
                if (d.i64(IFACE_ATA, "SmartNumAttributesFailing") > 0) return "warning";
                return "good";
            }
            if (d.has(IFACE_NVME)) {
                var warn = d.prop(IFACE_NVME, "SmartCriticalWarning");
                if (warn == null) return "";
                return warn.n_children() > 0 ? "warning" : "good";
            }
            return "";
        }

        private static void volume_entry(Json.Builder b, UDisksClient c, UObject v) {
            b.begin_object();
            b.set_member_name("device").add_string_value(v.device());
            string label = v.str(IFACE_BLOCK, "IdLabel");
            if (label != "") b.set_member_name("label").add_string_value(label);
            b.set_member_name("type").add_string_value(Format.filesystem_name(v.str(IFACE_BLOCK, "IdType"), v.str(IFACE_BLOCK, "IdVersion")));
            b.set_member_name("size").add_string_value(Format.size(v.u64(IFACE_BLOCK, "Size")));
            if (v.flag(IFACE_BLOCK, "HintSystem")) b.set_member_name("system").add_boolean_value(true);
            if (v.flag(IFACE_BLOCK, "ReadOnly")) b.set_member_name("read_only").add_boolean_value(true);
            if (v.has(IFACE_ENCRYPTED)) b.set_member_name("locked").add_boolean_value(c.cleartext(v) == null);
            if (v.has(IFACE_FILESYSTEM)) {
                var mounts = v.mount_points();
                if (mounts.length > 0) {
                    b.set_member_name("mounted_at").add_string_value(mounts[0]);
                    try {
                        var info = File.new_for_path(mounts[0]).query_filesystem_info("filesystem::free");
                        b.set_member_name("free").add_string_value(Format.size(info.get_attribute_uint64("filesystem::free")));
                    } catch (Error e) {
                    }
                } else {
                    b.set_member_name("mounted").add_boolean_value(false);
                }
            }
            var crypto = v.str(IFACE_BLOCK, "CryptoBackingDevice");
            if (crypto != "" && crypto != "/") {
                var backing = c.lookup(crypto);
                if (backing != null) b.set_member_name("unlocked_from").add_string_value(backing.device());
            }
            b.end_object();
        }

        private static async void wait_for(UDisksClient c, owned SourceFunc check) {
            for (int i = 0; i < 20 && !check(); i++) {
                Timeout.add(150, wait_for.callback);
                yield;
            }
        }

        private static async void list(DisksApp app, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                var c = yield udisks();
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("drives").begin_array();
                foreach (var d in c.drives()) {
                    b.begin_object();
                    b.set_member_name("id").add_string_value(Path.get_basename(d.path));
                    string model = (d.str(IFACE_DRIVE, "Vendor") + " " + d.str(IFACE_DRIVE, "Model")).strip();
                    b.set_member_name("model").add_string_value(model);
                    b.set_member_name("size").add_string_value(Format.size(d.u64(IFACE_DRIVE, "Size")));
                    string bus = d.str(IFACE_DRIVE, "ConnectionBus");
                    if (bus != "") b.set_member_name("connection").add_string_value(bus);
                    if (d.flag(IFACE_DRIVE, "Removable") || d.flag(IFACE_DRIVE, "MediaRemovable")) b.set_member_name("removable").add_boolean_value(true);
                    if (d.flag(IFACE_DRIVE, "MediaRemovable") && !d.flag(IFACE_DRIVE, "MediaAvailable")) b.set_member_name("no_media").add_boolean_value(true);
                    string h = health(d);
                    if (h != "") b.set_member_name("health").add_string_value(h);
                    var block = c.block_for_drive(d);
                    if (block != null) b.set_member_name("device").add_string_value(block.device());
                    b.set_member_name("volumes").begin_array();
                    foreach (var o in c.all()) {
                        if (!is_volume(o)) continue;
                        var owner = c.drive_for_block(o);
                        if (owner == null) {
                            var crypto = o.str(IFACE_BLOCK, "CryptoBackingDevice");
                            var backing = crypto != "" && crypto != "/" ? c.lookup(crypto) : null;
                            if (backing != null) owner = c.drive_for_block(backing);
                        }
                        if (owner == null || owner.path != d.path) continue;
                        volume_entry(b, c, o);
                    }
                    b.end_array();
                    b.end_object();
                }
                b.end_array();
                b.set_member_name("disk_images").begin_array();
                foreach (var l in c.loop_devices()) {
                    b.begin_object();
                    b.set_member_name("device").add_string_value(l.device());
                    var file = l.prop(IFACE_LOOP, "BackingFile");
                    if (file != null) b.set_member_name("file").add_string_value(UObject.bytestring(file));
                    b.set_member_name("volumes").begin_array();
                    foreach (var o in c.all()) {
                        if (!is_volume(o)) continue;
                        if (o.path == l.path || (o.has(IFACE_PARTITION) && o.str(IFACE_PARTITION, "Table") == l.path)) volume_entry(b, c, o);
                    }
                    b.end_array();
                    b.end_object();
                }
                b.end_array();
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void mount(DisksApp app, Json.Object args, bool want, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                var c = yield udisks();
                var v = find_volume(c, text(args, "volume"));
                if (!v.has(IFACE_FILESYSTEM)) throw new IOError.NOT_SUPPORTED("%s has no file system to mount", volume_name(v));
                if (want && v.mount_points().length > 0) throw new IOError.EXISTS("%s is already mounted at %s", volume_name(v), v.mount_points()[0]);
                if (!want && v.mount_points().length == 0) throw new IOError.NOT_MOUNTED("%s is not mounted", volume_name(v));
                if (!want && v.flag(IFACE_BLOCK, "HintSystem")) {
                    foreach (string m in v.mount_points()) if (m == "/" || m == "/usr" || m == "/boot" || m == "/home") throw new IOError.PERMISSION_DENIED("%s holds the system and stays mounted", volume_name(v));
                }
                string where = "";
                if (want) {
                    var r = yield v.call(IFACE_FILESYSTEM, "Mount", new Variant.tuple({ empty_options() }));
                    r.get("(s)", out where);
                    yield wait_for(c, () => v.mount_points().length > 0);
                } else {
                    yield v.call(IFACE_FILESYSTEM, "Unmount", new Variant.tuple({ empty_options() }));
                    yield wait_for(c, () => v.mount_points().length == 0);
                }
                bool now = v.mount_points().length > 0;
                if (now != want) throw new IOError.FAILED("%s did not %s", volume_name(v), want ? "mount" : "unmount");
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("volume").add_string_value(volume_name(v));
                if (want) b.set_member_name("mounted_at").add_string_value(where != "" ? where : v.mount_points()[0]);
                else b.set_member_name("unmounted").add_boolean_value(true);
                b.set_member_name("undo").add_string_value((want ? "disks_unmount" : "disks_mount") + " with volume " + v.device());
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void eject(DisksApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                var c = yield udisks();
                var d = find_drive(c, text(args, "drive"));
                bool can_eject = d.flag(IFACE_DRIVE, "Ejectable");
                bool can_off = d.flag(IFACE_DRIVE, "CanPowerOff");
                if (!can_eject && !can_off) throw new IOError.NOT_SUPPORTED("%s cannot be ejected safely; it is a fixed drive", d.str(IFACE_DRIVE, "Model"));
                var unmounted = new Gee.ArrayList<string>();
                foreach (var o in c.all()) {
                    if (!is_volume(o) || !o.has(IFACE_FILESYSTEM) || o.mount_points().length == 0) continue;
                    var owner = c.drive_for_block(o);
                    if (owner == null) {
                        var crypto = o.str(IFACE_BLOCK, "CryptoBackingDevice");
                        var backing = crypto != "" && crypto != "/" ? c.lookup(crypto) : null;
                        if (backing != null) owner = c.drive_for_block(backing);
                    }
                    if (owner == null || owner.path != d.path) continue;
                    if (o.flag(IFACE_BLOCK, "HintSystem")) throw new IOError.PERMISSION_DENIED("%s holds a system volume", d.str(IFACE_DRIVE, "Model"));
                    yield o.call(IFACE_FILESYSTEM, "Unmount", new Variant.tuple({ empty_options() }));
                    unmounted.add(volume_name(o));
                }
                if (can_eject) yield d.call(IFACE_DRIVE, "Eject", new Variant.tuple({ empty_options() }));
                if (can_off) yield d.call(IFACE_DRIVE, "PowerOff", new Variant.tuple({ empty_options() }));
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("drive").add_string_value((d.str(IFACE_DRIVE, "Vendor") + " " + d.str(IFACE_DRIVE, "Model")).strip());
                b.set_member_name("unmounted").begin_array();
                foreach (string n in unmounted) b.add_string_value(n);
                b.end_array();
                b.set_member_name("safe_to_remove").add_boolean_value(true);
                b.set_member_name("undo").add_string_value("unplug the drive and plug it back in");
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void health_report(DisksApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                var c = yield udisks();
                var d = find_drive(c, text(args, "drive"));
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("drive").add_string_value((d.str(IFACE_DRIVE, "Vendor") + " " + d.str(IFACE_DRIVE, "Model")).strip());
                string h = health(d);
                b.set_member_name("health").add_string_value(h != "" ? h : "not reported");
                if (d.has(IFACE_ATA) && d.flag(IFACE_ATA, "SmartEnabled")) {
                    double k = d.dbl(IFACE_ATA, "SmartTemperature");
                    if (k > 0) b.set_member_name("temperature").add_string_value(Format.temperature(k));
                    uint64 on = d.u64(IFACE_ATA, "SmartPowerOnSeconds");
                    if (on > 0) b.set_member_name("powered_on").add_string_value(Format.duration((int64) on));
                    b.set_member_name("bad_sectors").add_int_value(d.i64(IFACE_ATA, "SmartNumBadSectors"));
                    b.set_member_name("failing_attributes").add_int_value(d.i64(IFACE_ATA, "SmartNumAttributesFailing"));
                }
                if (d.has(IFACE_NVME)) {
                    uint64 k = d.u64(IFACE_NVME, "SmartTemperature");
                    if (k > 0) b.set_member_name("temperature").add_string_value(Format.temperature((double) k));
                    uint64 hours = d.u64(IFACE_NVME, "SmartPowerOnHours");
                    if (hours > 0) b.set_member_name("powered_on").add_string_value(Format.duration((int64) hours * 3600));
                    var warn = d.prop(IFACE_NVME, "SmartCriticalWarning");
                    if (warn != null && warn.n_children() > 0) {
                        b.set_member_name("warnings").begin_array();
                        for (size_t i = 0; i < warn.n_children(); i++) b.add_string_value(warn.get_child_value(i).get_string());
                        b.end_array();
                    }
                }
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void attach(DisksApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                string path = text(args, "file");
                if (path.has_prefix("~/")) path = Path.build_filename(Environment.get_home_dir(), path.substring(2));
                if (path == "" || !Path.is_absolute(path)) throw new IOError.INVALID_ARGUMENT("give the full path of the disk image");
                if (!FileUtils.test(path, FileTest.IS_REGULAR)) throw new IOError.NOT_FOUND("no file %s", path);
                bool read_only = !args.has_member("writable") || !args.get_boolean_member("writable");
                var c = yield udisks();
                string loop_path = yield c.loop_setup(path, read_only);
                yield wait_for(c, () => c.lookup(loop_path) != null);
                var loop = c.lookup(loop_path);
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("device").add_string_value(loop != null ? loop.device() : loop_path);
                b.set_member_name("read_only").add_boolean_value(read_only);
                b.set_member_name("undo").add_string_value("disks_detach_image with device " + (loop != null ? loop.device() : loop_path));
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void detach(DisksApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                var c = yield udisks();
                string wanted = text(args, "device");
                UObject? loop = null;
                foreach (var l in c.loop_devices()) if (l.device() == wanted || l.path == wanted) loop = l;
                if (loop == null) throw new IOError.NOT_FOUND("no attached disk image %s; see disks_list", wanted);
                foreach (var o in c.all()) {
                    if (!o.has(IFACE_FILESYSTEM) || o.mount_points().length == 0) continue;
                    if (o.path == loop.path || (o.has(IFACE_PARTITION) && o.str(IFACE_PARTITION, "Table") == loop.path))
                        yield o.call(IFACE_FILESYSTEM, "Unmount", new Variant.tuple({ empty_options() }));
                }
                string file = "";
                var backing = loop.prop(IFACE_LOOP, "BackingFile");
                if (backing != null) file = UObject.bytestring(backing);
                string loop_path = loop.path;
                yield loop.call(IFACE_LOOP, "Delete", new Variant.tuple({ empty_options() }));
                yield wait_for(c, () => {
                    var l = c.lookup(loop_path);
                    return l == null || !l.has(IFACE_LOOP) || l.u64(IFACE_BLOCK, "Size") == 0;
                });
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("detached").add_string_value(wanted);
                if (file != "") b.set_member_name("undo").add_string_value("disks_attach_image with file " + file);
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        internal static void install(DisksApp app) {
            var agent = app.agent;
            agent.add_async_intent("disks_list", "The drives and attached disk images, with their volumes, file systems, sizes, free space, where they are mounted and drive health.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args, reply) => {
                    list.begin(app, (owned) reply);
                });
            agent.add_async_intent("disks_mount", "Mount a volume so its files can be opened.",
                "{\"type\":\"object\",\"properties\":{\"volume\":{\"type\":\"string\",\"description\":\"device, label or mount point\"}},\"required\":[\"volume\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    mount.begin(app, args, true, (owned) reply);
                });
            agent.add_async_intent("disks_unmount", "Unmount a volume. System volumes stay mounted.",
                "{\"type\":\"object\",\"properties\":{\"volume\":{\"type\":\"string\"}},\"required\":[\"volume\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    mount.begin(app, args, false, (owned) reply);
                });
            agent.add_async_intent("disks_eject", "Safely remove a USB stick, card or other removable drive: unmount it and power it off.",
                "{\"type\":\"object\",\"properties\":{\"drive\":{\"type\":\"string\",\"description\":\"drive id, model, device or one of its volume labels\"}},\"required\":[\"drive\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    eject.begin(app, args, (owned) reply);
                });
            agent.add_async_intent("disks_health", "The health of a drive as the drive itself reports it (SMART): status, temperature, hours on, bad sectors.",
                "{\"type\":\"object\",\"properties\":{\"drive\":{\"type\":\"string\"}},\"required\":[\"drive\"]}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    health_report.begin(app, args, (owned) reply);
                });
            agent.add_async_intent("disks_attach_image", "Attach a disk image file (.img, .iso) as a drive, read only unless writable is true.",
                "{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\"},\"writable\":{\"type\":\"boolean\"}},\"required\":[\"file\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    attach.begin(app, args, (owned) reply);
                });
            agent.add_async_intent("disks_detach_image", "Detach an attached disk image, unmounting its volumes first.",
                "{\"type\":\"object\",\"properties\":{\"device\":{\"type\":\"string\"}},\"required\":[\"device\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    detach.begin(app, args, (owned) reply);
                });
        }
    }
}
