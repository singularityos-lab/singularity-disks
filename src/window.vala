using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Disks {

    public class DisksWindow : Singularity.Widgets.Window {
        private DisksApp app;
        private UDisksClient? client = null;
        private AppSidebar sidebar;
        private Stack stack;
        private StatusPage empty_page;
        private WelcomePage welcome_page;
        private Box page;
        private Image drive_icon;
        private Label drive_title;
        private Label drive_subtitle;
        private Button drive_menu_button;
        private Grid drive_info;
        private Box jobs_box;
        private VolumeBar? volume_bar = null;
        private Box bar_slot;
        private Box volume_actions;
        private Grid volume_info;
        private Label volumes_title;
        private string? selected_path = null;
        private string? volume_path = null;
        private Segment? current_segment = null;
        private UObject? current_inner = null;
        private string sidebar_signature = "";
        private string page_signature = "";
        private SizeGroup key_group = new SizeGroup (SizeGroupMode.HORIZONTAL);
        private Gee.HashMap<string, SidebarRow> rows = new Gee.HashMap<string, SidebarRow> ();

        public DisksWindow (DisksApp app) {
            Object (application: app);
            this.app = app;
            set_default_size (1020, 760);
            set_title (_("Disks"));

            sidebar = new AppSidebar (230);
            set_sidebar (sidebar);
            set_sidebar_visible (true);

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            empty_page = new StatusPage ();
            empty_page.icon_name = "drive-harddisk-symbolic";
            empty_page.title = _("Loading Drives");
            stack.add_named (empty_page, "empty");
            welcome_page = new WelcomePage ();
            welcome_page.app_icon_name = "dev.sinty.disks";
            welcome_page.title = _("Disks");
            welcome_page.subtitle = _("Connect a drive to see it here, or work with a disk image.");
            welcome_page.add_action ("media-optical", _("Attach Disk Image"), _("Open an ISO or IMG file as a drive"), () => app.activate_action ("attach-image", null));
            stack.add_named (welcome_page, "welcome");
            stack.add_named (build_page (), "page");
            stack.visible_child_name = "empty";
            set_content (stack);

            add_bubble_icon ("list-add-symbolic", _("Attach Disk Image"), () => app.activate_action ("attach-image", null));
            drive_menu_button = add_bubble_icon ("view-more-symbolic", _("Drive Actions"), show_drive_menu);
            drive_menu_button.visible = false;

            install_menu_actions ();
            connect_service.begin ();
        }

        private void menu_action (string name, owned Action callback) {
            var a = new SimpleAction (name, null);
            a.activate.connect (() => callback ());
            a.set_enabled (false);
            add_action (a);
        }

        private void enable (string name, bool on) {
            var a = lookup_action (name) as SimpleAction;
            if (a != null) a.set_enabled (on);
        }

        private UObject? selected_target () {
            return client != null ? client.lookup (selected_path) : null;
        }

        private UObject? selected_block () {
            if (selected_target () == null || current_segment == null || current_segment.free) return null;
            return current_inner ?? current_segment.block;
        }

        private void install_menu_actions () {
            var close_action = new SimpleAction ("close", null);
            close_action.activate.connect (() => close ());
            add_action (close_action);
            var sidebar_action = new SimpleAction ("toggle-sidebar", null);
            sidebar_action.activate.connect (() => set_sidebar_visible (!get_sidebar_visible ()));
            add_action (sidebar_action);
            menu_action ("format-disk", () => {
                var t = selected_target ();
                var disk = t != null ? disk_block (t) : null;
                if (disk != null) new FormatDiskDialog (app, disk).present ();
            });
            menu_action ("create-disk-image", () => {
                var t = selected_target ();
                var disk = t != null ? disk_block (t) : null;
                if (disk != null) new ImageDialog (app, disk, false).present ();
            });
            menu_action ("restore-disk-image", () => {
                var t = selected_target ();
                var disk = t != null ? disk_block (t) : null;
                if (disk != null) new ImageDialog (app, disk, true).present ();
            });
            menu_action ("benchmark-disk", () => {
                var t = selected_target ();
                var disk = t != null ? disk_block (t) : null;
                if (disk != null) new BenchmarkDialog (app, disk).present ();
            });
            menu_action ("drive-health", () => {
                var t = selected_target ();
                if (t != null) new SmartDialog (app, client, t).present ();
            });
            menu_action ("drive-settings", () => {
                var t = selected_target ();
                if (t != null) new DriveSettingsDialog (app, t).present ();
            });
            menu_action ("standby", () => {
                var t = selected_target ();
                if (t != null) run_call.begin (t, IFACE_ATA, "PmStandby", new Variant ("(@a{sv})", empty_options ()));
            });
            menu_action ("wake-up", () => {
                var t = selected_target ();
                if (t != null) run_call.begin (t, IFACE_ATA, "PmWakeup", new Variant ("(@a{sv})", empty_options ()));
            });
            menu_action ("eject", () => {
                var t = selected_target ();
                if (t != null) eject.begin (t, disk_block (t), false);
            });
            menu_action ("safely-remove", () => {
                var t = selected_target ();
                if (t != null) eject.begin (t, disk_block (t), true);
            });
            menu_action ("detach-image", () => {
                var t = selected_target ();
                if (t != null) detach.begin (t);
            });
            menu_action ("create-partition", () => {
                var t = selected_target ();
                var disk = t != null ? disk_block (t) : null;
                if (disk != null && current_segment != null && current_segment.free) new CreatePartitionDialog (app, client, disk, current_segment).present ();
            });
            menu_action ("mount", () => {
                var b = selected_block ();
                if (b != null) mount.begin (b);
            });
            menu_action ("unmount", () => {
                var b = selected_block ();
                if (b != null) run_call.begin (b, IFACE_FILESYSTEM, "Unmount", new Variant ("(@a{sv})", empty_options ()));
            });
            menu_action ("unlock", () => {
                if (selected_block () != null) new UnlockDialog (app, current_segment.block).present ();
            });
            menu_action ("lock", () => {
                if (selected_block () == null) return;
                var clear_obj = client.cleartext (current_segment.block);
                if (clear_obj != null) lock_volume.begin (current_segment.block, clear_obj);
            });
            menu_action ("format-volume", () => {
                var b = selected_block ();
                if (b != null) new FormatVolumeDialog (app, client, b).present ();
            });
            menu_action ("edit-partition", () => {
                if (selected_block () == null) return;
                var table = client.lookup (current_segment.block.str (IFACE_PARTITION, "Table"));
                if (table != null) new EditPartitionDialog (app, table, current_segment.block).present ();
            });
            menu_action ("resize", () => {
                var t = selected_target ();
                if (selected_block () != null) new ResizeDialog (app, client, current_segment.block, resize_limit (disk_block (t), current_segment)).present ();
            });
            menu_action ("rename", () => {
                var b = selected_block ();
                if (b != null) new LabelDialog (app, b).present ();
            });
            menu_action ("mount-options", () => {
                var b = selected_block ();
                if (b != null) new MountOptionsDialog (app, b).present ();
            });
            menu_action ("check-filesystem", () => {
                var b = selected_block ();
                if (b != null) check_filesystem.begin (b, false);
            });
            menu_action ("repair-filesystem", () => {
                var b = selected_block ();
                if (b != null) check_filesystem.begin (b, true);
            });
            menu_action ("change-passphrase", () => {
                if (selected_block () != null) new PassphraseDialog (app, current_segment.block).present ();
            });
            menu_action ("create-volume-image", () => {
                if (selected_block () != null) new ImageDialog (app, current_segment.block, false).present ();
            });
            menu_action ("restore-volume-image", () => {
                if (selected_block () != null) new ImageDialog (app, current_segment.block, true).present ();
            });
            menu_action ("benchmark-volume", () => {
                if (selected_block () != null) new BenchmarkDialog (app, current_segment.block).present ();
            });
            menu_action ("delete-partition", () => {
                if (selected_block () != null) confirm_delete (current_segment.block);
            });
        }

        private void sync_actions () {
            var target = selected_target ();
            var disk = target != null ? disk_block (target) : null;
            bool has_disk = disk != null && disk.u64 (IFACE_BLOCK, "Size") > 0;
            bool drive = target != null && target.has (IFACE_DRIVE);
            bool ata = drive && target.has (IFACE_ATA);
            bool pm = ata && target.flag (IFACE_ATA, "PmSupported") && target.flag (IFACE_ATA, "PmEnabled");
            enable ("format-disk", has_disk);
            enable ("create-disk-image", has_disk);
            enable ("restore-disk-image", has_disk);
            enable ("benchmark-disk", has_disk);
            enable ("drive-health", drive && (ata || target.has (IFACE_NVME)));
            enable ("drive-settings", ata);
            enable ("standby", pm);
            enable ("wake-up", pm);
            enable ("eject", drive && target.flag (IFACE_DRIVE, "Ejectable"));
            enable ("safely-remove", drive && target.flag (IFACE_DRIVE, "CanPowerOff"));
            enable ("detach-image", target != null && target.has (IFACE_LOOP));
            enable ("create-partition", target != null && current_segment != null && current_segment.free && disk != null && disk.has (IFACE_TABLE));
            var block = selected_block ();
            var part = block != null ? current_segment.block : null;
            bool fs = block != null && block.has (IFACE_FILESYSTEM);
            bool mounted = fs && block.mount_points ().length > 0;
            bool encrypted = part != null && part.has (IFACE_ENCRYPTED);
            bool unlocked = encrypted && client.cleartext (part) != null;
            bool swap = block != null && block.has (IFACE_SWAP) && block.flag (IFACE_SWAP, "Active");
            bool is_part = part != null && part.has (IFACE_PARTITION) && current_inner == null;
            bool container = part != null && part.has (IFACE_PARTITION) && part.flag (IFACE_PARTITION, "IsContainer");
            bool busy = (current_inner == null && unlocked) || mounted || swap;
            enable ("mount", fs && !mounted);
            enable ("unmount", mounted);
            enable ("unlock", encrypted && !unlocked);
            enable ("lock", unlocked);
            enable ("format-volume", block != null && !busy && !container);
            enable ("edit-partition", is_part && client.lookup (part.str (IFACE_PARTITION, "Table")) != null);
            enable ("resize", is_part && !container && !unlocked);
            enable ("rename", fs);
            enable ("mount-options", fs);
            enable ("check-filesystem", fs && !busy);
            enable ("repair-filesystem", fs && !busy);
            enable ("change-passphrase", encrypted);
            enable ("create-volume-image", block != null);
            enable ("restore-volume-image", block != null && !busy);
            enable ("benchmark-volume", block != null);
            enable ("delete-partition", is_part && !mounted && !swap && !unlocked);
        }

        private async void connect_service () {
            try {
                client = yield UDisksClient.create ();
            } catch (Error e) {
                empty_page.icon_name = "dialog-error-symbolic";
                empty_page.title = _("Disks Are Not Available");
                empty_page.description = _("The disk service could not be reached: %s").printf (describe_error (e));
                return;
            }
            volume_bar = new VolumeBar (client);
            volume_bar.activated.connect (on_volume);
            bar_slot.append (volume_bar);
            client.changed.connect (refresh);
            refresh ();
        }

        public UDisksClient? disks_client () {
            return client;
        }

        public static void show_menu (ContextMenu menu) {
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        public static string describe_error (Error e) {
            string remote = DBusError.get_remote_error (e) ?? "";
            var copy = e.copy ();
            DBusError.strip_remote_error (copy);
            string message = copy.message.strip ();
            if (remote.has_suffix ("NotAuthorized") || remote.has_suffix ("NotAuthorizedCanObtain") || remote.has_suffix ("NotAuthorizedDismissed")) {
                return _("You are not allowed to do this, or the password was not entered.");
            }
            if (remote.has_suffix ("DeviceBusy") || message.contains ("target is busy")) {
                return _("The device is in use. Close any files or apps using it and try again.");
            }
            if (remote.has_suffix ("Cancelled")) return _("The operation was cancelled.");
            if (message.contains ("No keyslot with given passphrase") || message.contains ("Failed to activate device: Operation not permitted")) {
                return _("The passphrase is not correct.");
            }
            int colon = message.last_index_of (": ");
            if (colon > 0 && colon < message.length - 2) message = message.substring (colon + 2);
            if (message.length > 0) message = message.substring (0, 1).up () + message.substring (1);
            if (message.length > 0 && !message.has_suffix (".")) message += ".";
            return message;
        }

        private Widget build_page () {
            page = new Box (Orientation.VERTICAL, 18);
            page.margin_top = 24;
            page.margin_bottom = 24;
            page.margin_start = 28;
            page.margin_end = 28;

            var header = new Box (Orientation.HORIZONTAL, 16);
            drive_icon = new Image ();
            drive_icon.pixel_size = 56;
            header.append (drive_icon);
            var titles = new Box (Orientation.VERTICAL, 2);
            titles.valign = Align.CENTER;
            titles.hexpand = true;
            drive_title = new Label ("");
            drive_title.xalign = 0;
            drive_title.add_css_class ("title-2");
            drive_title.ellipsize = Pango.EllipsizeMode.END;
            drive_subtitle = new Label ("");
            drive_subtitle.xalign = 0;
            drive_subtitle.add_css_class ("dim-label");
            titles.append (drive_title);
            titles.append (drive_subtitle);
            header.append (titles);
            page.append (header);

            drive_info = info_grid ();
            page.append (drive_info);

            jobs_box = new Box (Orientation.VERTICAL, 8);
            page.append (jobs_box);

            volumes_title = new Label (_("Volumes"));
            volumes_title.xalign = 0;
            volumes_title.add_css_class ("heading");
            page.append (volumes_title);

            bar_slot = new Box (Orientation.VERTICAL, 0);
            page.append (bar_slot);

            volume_actions = new Box (Orientation.HORIZONTAL, 6);
            volume_actions.add_css_class ("disks-volume-actions");
            page.append (volume_actions);

            volume_info = info_grid ();
            page.append (volume_info);

            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            var clamp = new Box (Orientation.VERTICAL, 0);
            clamp.append (page);
            scroll.child = clamp;
            return scroll;
        }

        private Grid info_grid () {
            var grid = new Grid ();
            grid.add_css_class ("disks-info");
            grid.column_spacing = 18;
            grid.row_spacing = 6;
            return grid;
        }

        private void clear (Widget container) {
            Widget? child;
            while ((child = container.get_first_child ()) != null) {
                if (child.get_data<bool> ("disks-key")) key_group.remove_widget (child);
                if (container is Grid) ((Grid) container).remove (child);
                else if (container is Box) ((Box) container).remove (child);
                else break;
            }
        }

        private int info_row (Grid grid, int row, string key, string value, Widget? extra = null) {
            if (value == "" && extra == null) return row;
            var k = new Label (key);
            k.xalign = 1;
            k.yalign = 0;
            k.add_css_class ("dim-label");
            if (extra != null) k.valign = Align.CENTER;
            key_group.add_widget (k);
            k.set_data<bool> ("disks-key", true);
            grid.attach (k, 0, row, 1, 1);
            if (extra != null) {
                var box = new Box (Orientation.HORIZONTAL, 8);
                if (value != "") {
                    var v = value_label (value);
                    v.hexpand = false;
                    box.append (v);
                }
                box.append (extra);
                grid.attach (box, 1, row, 1, 1);
            } else {
                grid.attach (value_label (value), 1, row, 1, 1);
            }
            return row + 1;
        }

        private Label value_label (string value) {
            var v = new Label (value);
            v.xalign = 0;
            v.hexpand = true;
            v.selectable = true;
            v.wrap = true;
            v.wrap_mode = Pango.WrapMode.WORD_CHAR;
            return v;
        }

        private void refresh () {
            if (client == null) return;
            refresh_sidebar ();
            var target = client.lookup (selected_path);
            if (target == null) {
                var drives = client.drives ();
                if (drives.size > 0) select (drives[0].path);
                else {
                    var loops = client.loop_devices ();
                    if (loops.size > 0) select (loops[0].path);
                    else show_empty ();
                }
                return;
            }
            string signature = page_state (target);
            if (signature != page_signature) {
                page_signature = signature;
                show_target (target);
            }
            refresh_jobs (target);
            sync_actions ();
        }

        private void show_empty () {
            selected_path = null;
            stack.visible_child_name = "welcome";
            drive_menu_button.visible = false;
            sync_actions ();
        }

        private string drive_name (UObject drive) {
            string vendor = drive.str (IFACE_DRIVE, "Vendor").strip ();
            string model = drive.str (IFACE_DRIVE, "Model").strip ();
            string name = model;
            if (vendor != "" && !model.has_prefix (vendor)) name = vendor + " " + model;
            if (name.strip () == "") name = _("Drive");
            return name.strip ();
        }

        private string drive_icon_name (UObject drive) {
            return drive_icon_base (drive) + "-symbolic";
        }

        private string drive_icon_base (UObject drive) {
            if (drive.flag (IFACE_DRIVE, "Optical") || drive.str (IFACE_DRIVE, "Media").has_prefix ("optical")) return "media-optical";
            string media = drive.str (IFACE_DRIVE, "Media");
            if (media.has_prefix ("flash")) return "media-flash";
            if (drive.flag (IFACE_DRIVE, "Removable") || drive.str (IFACE_DRIVE, "ConnectionBus") == "usb") return "drive-removable-media";
            return "drive-harddisk";
        }

        private string drive_header_icon (UObject drive) {
            string base_name = drive_icon_base (drive);
            if (base_name == "drive-harddisk" && drive.prop (IFACE_DRIVE, "RotationRate") != null && drive.i64 (IFACE_DRIVE, "RotationRate") == 0) return "drive-harddisk-solidstate";
            if (base_name == "drive-removable-media" && drive.str (IFACE_DRIVE, "ConnectionBus") == "usb" && !drive.flag (IFACE_DRIVE, "MediaRemovable")) return "drive-harddisk-usb";
            return base_name;
        }

        private string drive_label (UObject drive) {
            uint64 size = drive.u64 (IFACE_DRIVE, "Size");
            if (size == 0 && client != null) {
                var block = client.block_for_drive (drive);
                if (block != null) size = block.u64 (IFACE_BLOCK, "Size");
            }
            string kind;
            if (drive.flag (IFACE_DRIVE, "Optical")) kind = _("Optical Drive");
            else if (drive.has (IFACE_NVME)) kind = _("NVMe Drive");
            else if (drive.i64 (IFACE_DRIVE, "RotationRate") == 0) kind = _("Solid-State Drive");
            else if (drive.flag (IFACE_DRIVE, "Removable")) kind = _("Removable Drive");
            else kind = _("Hard Disk");
            if (drive.flag (IFACE_DRIVE, "MediaRemovable") && !drive.flag (IFACE_DRIVE, "MediaAvailable")) return _("%s, no media").printf (kind);
            return size > 0 ? "%s %s".printf (Format.size (size), kind) : kind;
        }

        private void refresh_sidebar () {
            var drives = client.drives ();
            var loops = client.loop_devices ();
            var sig = new StringBuilder ();
            foreach (var d in drives) sig.append ("%s|%s|%s;".printf (d.path, drive_label (d), drive_name (d)));
            foreach (var l in loops) sig.append ("%s|%s;".printf (l.path, loop_file (l)));
            if (sig.str == sidebar_signature) {
                sync_active ();
                return;
            }
            sidebar_signature = sig.str;
            rows.clear ();
            clear (sidebar.box);
            if (drives.size > 0) sidebar.box.append (new SidebarSectionLabel (_("Drives")));
            foreach (var d in drives) add_row (d.path, drive_icon_name (d), drive_name (d), drive_label (d));
            if (loops.size > 0) sidebar.box.append (new SidebarSectionLabel (_("Disk Images")));
            foreach (var l in loops) {
                string file = loop_file (l);
                add_row (l.path, "media-optical-symbolic", file != "" ? Path.get_basename (file) : l.device (), Format.size (l.u64 (IFACE_BLOCK, "Size")));
            }
            sync_active ();
        }

        private void add_row (string path, string icon, string name, string detail) {
            var row = new SidebarRow (icon, name);
            row.tooltip_text = "%s\n%s".printf (name, detail);
            row.clicked.connect (() => select (path));
            rows[path] = row;
            sidebar.box.append (row);
        }

        private void sync_active () {
            foreach (var entry in rows.entries) entry.value.set_active (entry.key == selected_path);
        }

        private string loop_file (UObject loop) {
            var v = loop.prop (IFACE_LOOP, "BackingFile");
            return v != null ? UObject.bytestring (v) : "";
        }

        public void select (string path) {
            if (selected_path != path) {
                selected_path = path;
                volume_path = null;
                page_signature = "";
            }
            sync_active ();
            refresh ();
        }

        private UObject? disk_block (UObject target) {
            return target.has (IFACE_DRIVE) ? client.block_for_drive (target) : target;
        }

        private string page_state (UObject target) {
            var sb = new StringBuilder (target.path);
            var disk = disk_block (target);
            if (target.has (IFACE_DRIVE)) {
                foreach (string p in new string[] { "MediaAvailable", "Size", "Model" }) {
                    var v = target.prop (IFACE_DRIVE, p);
                    sb.append (v != null ? v.print (false) : "-");
                }
                if (target.has (IFACE_ATA)) {
                    sb.append (target.flag (IFACE_ATA, "SmartFailing") ? "F" : "f");
                    sb.append (target.i64 (IFACE_ATA, "SmartNumBadSectors").to_string ());
                }
            }
            if (disk == null) return sb.str;
            sb.append (disk.path);
            sb.append (disk.has (IFACE_TABLE) ? disk.str (IFACE_TABLE, "Type") : "-");
            foreach (var seg in client.layout (disk)) {
                sb.append ("|%llu:%llu".printf (seg.offset, seg.size));
                if (seg.block == null) continue;
                append_block (sb, seg.block);
                if (seg.block.has (IFACE_ENCRYPTED)) {
                    var clear_obj = client.cleartext (seg.block);
                    if (clear_obj != null) append_block (sb, clear_obj);
                }
            }
            return sb.str;
        }

        private void append_block (StringBuilder sb, UObject b) {
            sb.append (b.path);
            foreach (string p in new string[] { "IdType", "IdLabel", "IdUUID", "Configuration", "ReadOnly" }) {
                var v = b.prop (IFACE_BLOCK, p);
                sb.append (v != null ? v.print (false) : "-");
            }
            sb.append (string.joinv (",", b.mount_points ()));
            if (b.has (IFACE_PARTITION)) {
                foreach (string p in new string[] { "Type", "Name", "Flags", "Size" }) {
                    var v = b.prop (IFACE_PARTITION, p);
                    sb.append (v != null ? v.print (false) : "-");
                }
            }
            if (b.has (IFACE_SWAP)) sb.append (b.flag (IFACE_SWAP, "Active") ? "S" : "s");
            if (b.has (IFACE_LOOP)) sb.append (b.flag (IFACE_LOOP, "Autoclear") ? "A" : "a");
        }

        private void show_target (UObject target) {
            stack.visible_child_name = "page";
            drive_menu_button.visible = true;
            clear (drive_info);
            var disk = disk_block (target);
            int row = 0;
            if (target.has (IFACE_DRIVE)) {
                drive_icon.icon_name = drive_header_icon (target);
                drive_title.label = drive_name (target);
                drive_subtitle.label = disk != null ? "%s, %s".printf (drive_label (target), disk.device ()) : drive_label (target);
                row = info_row (drive_info, row, _("Model"), "%s %s".printf (drive_name (target), target.str (IFACE_DRIVE, "Revision")).strip ());
                row = info_row (drive_info, row, _("Serial Number"), target.str (IFACE_DRIVE, "Serial"));
                uint64 size = target.u64 (IFACE_DRIVE, "Size");
                if (size == 0 && disk != null) size = disk.u64 (IFACE_BLOCK, "Size");
                if (size > 0) row = info_row (drive_info, row, _("Size"), Format.size_long (size));
                string bus = target.str (IFACE_DRIVE, "ConnectionBus");
                if (bus != "") row = info_row (drive_info, row, _("Connection"), bus.up ());
                int64 rpm = target.i64 (IFACE_DRIVE, "RotationRate");
                if (rpm > 0) row = info_row (drive_info, row, _("Rotation"), _("%lld RPM").printf (rpm));
                string health = health_summary (target);
                if (health != "") {
                    var details = new Button.with_label (_("Details"));
                    details.add_css_class ("flat");
                    details.clicked.connect (() => new SmartDialog (app, client, target).present ());
                    row = info_row (drive_info, row, _("Health"), health, details);
                }
            } else {
                drive_icon.icon_name = "media-optical";
                string file = loop_file (target);
                drive_title.label = file != "" ? Path.get_basename (file) : target.device ();
                drive_subtitle.label = _("%s Disk Image, %s").printf (Format.size (target.u64 (IFACE_BLOCK, "Size")), target.device ());
                row = info_row (drive_info, row, _("Image File"), file);
                row = info_row (drive_info, row, _("Size"), Format.size_long (target.u64 (IFACE_BLOCK, "Size")));
                var autoclear = new Switch ();
                autoclear.active = target.flag (IFACE_LOOP, "Autoclear");
                autoclear.valign = Align.CENTER;
                autoclear.notify["active"].connect (() => {
                    if (autoclear.active == target.flag (IFACE_LOOP, "Autoclear")) return;
                    run_call.begin (target, IFACE_LOOP, "SetAutoclear", new Variant ("(b@a{sv})", autoclear.active, empty_options ()));
                });
                row = info_row (drive_info, row, _("Detach When Unused"), "", autoclear);
                if (target.flag (IFACE_BLOCK, "ReadOnly")) row = info_row (drive_info, row, _("Access"), _("Read-Only"));
            }
            if (disk != null) {
                string scheme = disk.has (IFACE_TABLE) ? partitioning_name (disk.str (IFACE_TABLE, "Type")) : _("None");
                row = info_row (drive_info, row, _("Partitioning"), scheme);
            }

            bool has_media = disk != null && disk.u64 (IFACE_BLOCK, "Size") > 0;
            volumes_title.visible = has_media;
            bar_slot.visible = has_media;
            volume_actions.visible = has_media;
            volume_info.visible = has_media;
            if (!has_media) return;
            volume_bar.set_segments (client.layout (disk), volume_path);
        }

        private string partitioning_name (string type) {
            if (type == "gpt") return _("GUID Partition Table (GPT)");
            if (type == "dos") return _("Master Boot Record (MBR)");
            return type;
        }

        private string health_summary (UObject drive) {
            if (drive.has (IFACE_NVME)) {
                var w = drive.prop (IFACE_NVME, "SmartCriticalWarning");
                string temp = Format.temperature ((double) drive.u64 (IFACE_NVME, "SmartTemperature"));
                string state = w != null && w.get_strv ().length > 0 ? _("Problem reported") : _("Healthy");
                return temp != "" ? "%s, %s".printf (state, temp) : state;
            }
            if (!drive.has (IFACE_ATA) || !drive.flag (IFACE_ATA, "SmartSupported")) return "";
            if (!drive.flag (IFACE_ATA, "SmartEnabled")) return _("Monitoring off");
            string state;
            if (drive.flag (IFACE_ATA, "SmartFailing")) state = _("Likely to fail soon");
            else if (drive.i64 (IFACE_ATA, "SmartNumAttributesFailing") > 0) state = _("Signs of wear");
            else if (drive.i64 (IFACE_ATA, "SmartNumBadSectors") > 0) state = _("Healthy, with bad sectors");
            else state = _("Healthy");
            string temp = Format.temperature (drive.dbl (IFACE_ATA, "SmartTemperature"));
            return temp != "" ? "%s, %s".printf (state, temp) : state;
        }

        private void on_volume (Segment segment, UObject? inner) {
            current_segment = segment;
            current_inner = inner;
            sync_actions ();
            volume_path = inner != null ? inner.path : (segment.block != null ? segment.block.path : null);
            clear (volume_info);
            clear (volume_actions);
            var target = client.lookup (selected_path);
            if (target == null) return;
            var disk = disk_block (target);
            if (segment.free) {
                int r = 0;
                r = info_row (volume_info, r, _("Size"), Format.size_long (segment.size));
                r = info_row (volume_info, r, _("Contents"), _("Unallocated Space"));
                if (disk != null && disk.has (IFACE_TABLE)) {
                    action (_("Create Partition"), "list-add-symbolic", () => new CreatePartitionDialog (app, client, disk, segment).present (), true);
                }
                return;
            }
            var block = inner ?? segment.block;
            int r = 0;
            string label = block.str (IFACE_BLOCK, "IdLabel");
            r = info_row (volume_info, r, _("Name"), label);
            if (block.has (IFACE_PARTITION) && inner == null) {
                string name = block.str (IFACE_PARTITION, "Name");
                if (name != "") r = info_row (volume_info, r, _("Partition Name"), name);
            }
            uint64 volume_size = inner == null && block.has (IFACE_PARTITION) ? block.u64 (IFACE_PARTITION, "Size") : block.u64 (IFACE_BLOCK, "Size");
            r = info_row (volume_info, r, _("Size"), Format.size_long (volume_size));
            r = info_row (volume_info, r, _("Contents"), contents (block));
            r = info_row (volume_info, r, _("Device"), block.device ());
            r = info_row (volume_info, r, _("UUID"), block.str (IFACE_BLOCK, "IdUUID"));
            if (segment.block.has (IFACE_PARTITION)) {
                var table = client.lookup (segment.block.str (IFACE_PARTITION, "Table"));
                string type = segment.block.str (IFACE_PARTITION, "Type");
                bool dos = table != null && table.str (IFACE_TABLE, "Type") == "dos";
                string type_name = dos ? Format.dos_type_name (type) : Format.gpt_type_name (type);
                r = info_row (volume_info, r, _("Partition Type"), "%s, %s".printf (type_name, _("partition %u").printf ((uint) segment.block.u64 (IFACE_PARTITION, "Number"))));
            }
            if (block.has (IFACE_FILESYSTEM)) {
                var points = block.mount_points ();
                if (points.length > 0) {
                    var open = new Button.with_label (_("Open"));
                    open.add_css_class ("flat");
                    string mount = points[0];
                    open.clicked.connect (() => {
                        var launcher = new FileLauncher (File.new_for_path (mount));
                        launcher.launch.begin (this, null);
                    });
                    r = info_row (volume_info, r, _("Mounted At"), string.joinv (", ", points), open);
                    string usage = usage_for (mount);
                    if (usage != "") r = info_row (volume_info, r, _("Space"), usage);
                } else {
                    r = info_row (volume_info, r, _("Mounted At"), _("Not mounted"));
                }
            }
            if (block.has (IFACE_SWAP)) r = info_row (volume_info, r, _("State"), block.flag (IFACE_SWAP, "Active") ? _("In use") : _("Not in use"));
            if (segment.block.has (IFACE_ENCRYPTED)) {
                r = info_row (volume_info, r, _("Encryption"), client.cleartext (segment.block) != null ? _("Unlocked") : _("Locked"));
            }
            build_actions (disk, segment, inner);
        }

        private string usage_for (string mount) {
            try {
                var info = File.new_for_path (mount).query_filesystem_info ("filesystem::size,filesystem::free", null);
                uint64 size = info.get_attribute_uint64 (FileAttribute.FILESYSTEM_SIZE);
                uint64 free = info.get_attribute_uint64 (FileAttribute.FILESYSTEM_FREE);
                if (size == 0) return "";
                return _("%s free of %s (%d%% used)").printf (Format.size (free), Format.size (size), (int) Math.round (100.0 * (size - free) / size));
            } catch (Error e) {
                return "";
            }
        }

        private string contents (UObject block) {
            string type = block.str (IFACE_BLOCK, "IdType");
            string usage = block.str (IFACE_BLOCK, "IdUsage");
            if (block.has (IFACE_PARTITION) && block.flag (IFACE_PARTITION, "IsContainer")) return _("Extended Partition");
            if (type == "" && usage == "") return _("Unknown");
            string name = Format.filesystem_name (type, block.str (IFACE_BLOCK, "IdVersion"));
            if (block.has (IFACE_FILESYSTEM)) {
                return block.mount_points ().length > 0 ? _("%s, mounted").printf (name) : _("%s, not mounted").printf (name);
            }
            return name;
        }

        private delegate void Action ();

        private Button action (string tooltip, string icon, owned Action callback, bool labelled = false) {
            Button button;
            if (labelled) {
                button = new Button ();
                var content = new Box (Orientation.HORIZONTAL, 6);
                content.append (new Image.from_icon_name (icon));
                content.append (new Label (tooltip));
                button.child = content;
            } else {
                button = new Button.from_icon_name (icon);
                button.tooltip_text = tooltip;
            }
            button.clicked.connect (() => callback ());
            volume_actions.append (button);
            return button;
        }

        private void build_actions (UObject? disk, Segment segment, UObject? inner) {
            var part = segment.block;
            var block = inner ?? part;
            if (block.has (IFACE_FILESYSTEM)) {
                if (block.mount_points ().length > 0) {
                    action (_("Unmount"), "media-playback-stop-symbolic", () => run_call.begin (block, IFACE_FILESYSTEM, "Unmount", new Variant ("(@a{sv})", empty_options ())), true);
                } else {
                    action (_("Mount"), "media-playback-start-symbolic", () => mount.begin (block), true);
                }
            }
            if (block.has (IFACE_SWAP)) {
                if (block.flag (IFACE_SWAP, "Active")) action (_("Stop Using Swap"), "media-playback-stop-symbolic", () => run_call.begin (block, IFACE_SWAP, "Stop", new Variant ("(@a{sv})", empty_options ())), true);
                else action (_("Use as Swap"), "media-playback-start-symbolic", () => run_call.begin (block, IFACE_SWAP, "Start", new Variant ("(@a{sv})", empty_options ())), true);
            }
            if (part.has (IFACE_ENCRYPTED)) {
                var clear_obj = client.cleartext (part);
                if (clear_obj != null) action (_("Lock"), "changes-prevent-symbolic", () => lock_volume.begin (part, clear_obj), true);
                else action (_("Unlock"), "changes-allow-symbolic", () => new UnlockDialog (app, part).present (), true);
            }
            if (part.has (IFACE_PARTITION) && inner == null) {
                var remove = action (_("Delete Partition"), "user-trash-symbolic", () => confirm_delete (part));
                bool in_use = block.mount_points ().length > 0 || (block.has (IFACE_SWAP) && block.flag (IFACE_SWAP, "Active")) || (part.has (IFACE_ENCRYPTED) && client.cleartext (part) != null);
                if (in_use) {
                    remove.sensitive = false;
                    remove.tooltip_text = _("Unmount or lock the volume before deleting it");
                }
            }
            var more = action (_("More Actions"), "view-more-symbolic", () => { });
            more.clicked.connect (() => show_volume_menu (more, disk, segment, inner));
        }

        private void show_volume_menu (Widget anchor, UObject? disk, Segment segment, UObject? inner) {
            var part = segment.block;
            var block = inner ?? part;
            var menu = new ContextMenu (anchor);
            bool unlocked = inner == null && part.has (IFACE_ENCRYPTED) && client.cleartext (part) != null;
            bool busy = unlocked || block.mount_points ().length > 0 || (block.has (IFACE_SWAP) && block.flag (IFACE_SWAP, "Active"));
            if (!busy && !(part.has (IFACE_PARTITION) && part.flag (IFACE_PARTITION, "IsContainer"))) {
                menu.add_item (_("Format"), "edit-clear-all-symbolic", () => new FormatVolumeDialog (app, client, block).present ());
            }
            if (part.has (IFACE_PARTITION) && inner == null) {
                var table = client.lookup (part.str (IFACE_PARTITION, "Table"));
                if (table != null) menu.add_item (_("Edit Partition"), "document-edit-symbolic", () => new EditPartitionDialog (app, table, part).present ());
                if (!part.flag (IFACE_PARTITION, "IsContainer") && !unlocked) {
                    uint64 max = resize_limit (disk, segment);
                    menu.add_item (_("Resize"), "view-fullscreen-symbolic", () => new ResizeDialog (app, client, part, max).present ());
                }
            }
            if (block.has (IFACE_FILESYSTEM)) {
                menu.add_item (_("Rename"), "document-edit-symbolic", () => new LabelDialog (app, block).present ());
                menu.add_item (_("Mount Options"), "emblem-system-symbolic", () => new MountOptionsDialog (app, block).present ());
                if (!busy) {
                    menu.add_item (_("Check Filesystem"), "object-select-symbolic", () => check_filesystem.begin (block, false));
                    menu.add_item (_("Repair Filesystem"), "applications-engineering-symbolic", () => check_filesystem.begin (block, true));
                }
                string type = block.str (IFACE_BLOCK, "IdType");
                if (block.mount_points ().length > 0 && (type == "ext2" || type == "ext3" || type == "ext4" || type == "btrfs" || type == "xfs")) {
                    menu.add_item (_("Take Ownership"), "avatar-default-symbolic", () => take_ownership (block));
                }
            }
            if (part.has (IFACE_ENCRYPTED)) {
                menu.add_item (_("Change Passphrase"), "dialog-password-symbolic", () => new PassphraseDialog (app, part).present ());
            }
            menu.add_separator ();
            menu.add_item (_("Create Image of Volume"), "document-save-symbolic", () => new ImageDialog (app, part, false).present ());
            if (!busy) menu.add_item (_("Restore Image to Volume"), "document-open-symbolic", () => new ImageDialog (app, part, true).present ());
            menu.add_item (_("Benchmark Volume"), "power-profile-performance-symbolic", () => new BenchmarkDialog (app, part).present ());
            DisksWindow.show_menu (menu);
        }

        private uint64 resize_limit (UObject? disk, Segment segment) {
            uint64 max = segment.size;
            if (disk == null) return max;
            var layout = client.layout (disk);
            for (int i = 0; i < layout.size; i++) {
                if (layout[i].block != segment.block) continue;
                if (i + 1 < layout.size && layout[i + 1].free && layout[i + 1].logical == segment.logical) {
                    max += layout[i + 1].size;
                }
                break;
            }
            return max;
        }

        private void show_drive_menu () {
            var target = client.lookup (selected_path);
            if (target == null) return;
            var disk = disk_block (target);
            var menu = new ContextMenu (stack);
            Graphene.Rect bounds;
            if (drive_menu_button.compute_bounds (stack, out bounds)) {
                var rect = Gdk.Rectangle ();
                rect.x = (int) bounds.origin.x;
                rect.y = (int) bounds.origin.y;
                rect.width = (int) bounds.size.width;
                rect.height = (int) bounds.size.height;
                menu.pointing_to = rect;
            }
            menu.position = PositionType.BOTTOM;
            if (disk != null && disk.u64 (IFACE_BLOCK, "Size") > 0) {
                menu.add_item (_("Format Disk"), "edit-clear-all-symbolic", () => new FormatDiskDialog (app, disk).present ());
                menu.add_separator ();
                menu.add_item (_("Create Disk Image"), "document-save-symbolic", () => new ImageDialog (app, disk, false).present ());
                menu.add_item (_("Restore Disk Image"), "document-open-symbolic", () => new ImageDialog (app, disk, true).present ());
                menu.add_item (_("Benchmark Disk"), "power-profile-performance-symbolic", () => new BenchmarkDialog (app, disk).present ());
            }
            if (target.has (IFACE_DRIVE)) {
                if (disk != null && disk.u64 (IFACE_BLOCK, "Size") > 0 && (target.has (IFACE_ATA) || target.has (IFACE_NVME))) menu.add_separator ();
                if (target.has (IFACE_ATA) || target.has (IFACE_NVME)) {
                    menu.add_item (_("Drive Health"), "object-select-symbolic", () => new SmartDialog (app, client, target).present ());
                }
                if (target.has (IFACE_ATA)) {
                    menu.add_item (_("Drive Settings"), "emblem-system-symbolic", () => new DriveSettingsDialog (app, target).present ());
                    if (target.flag (IFACE_ATA, "PmSupported") && target.flag (IFACE_ATA, "PmEnabled")) {
                        menu.add_item (_("Standby Now"), "media-playback-pause-symbolic", () => run_call.begin (target, IFACE_ATA, "PmStandby", new Variant ("(@a{sv})", empty_options ())));
                        menu.add_item (_("Wake Up"), "media-playback-start-symbolic", () => run_call.begin (target, IFACE_ATA, "PmWakeup", new Variant ("(@a{sv})", empty_options ())));
                    }
                }
                if (target.flag (IFACE_DRIVE, "Ejectable")) {
                    menu.add_separator ();
                    menu.add_item (_("Eject"), "media-eject-symbolic", () => eject.begin (target, disk, false));
                }
                if (target.flag (IFACE_DRIVE, "CanPowerOff")) {
                    if (!target.flag (IFACE_DRIVE, "Ejectable")) menu.add_separator ();
                    menu.add_item (_("Safely Remove"), "system-shutdown-symbolic", () => eject.begin (target, disk, true));
                }
            } else if (target.has (IFACE_LOOP)) {
                menu.add_separator ();
                menu.add_item (_("Detach Image"), "media-eject-symbolic", () => detach.begin (target));
            }
            DisksWindow.show_menu (menu);
        }

        private void refresh_jobs (UObject target) {
            clear (jobs_box);
            var seen = new Gee.HashSet<string> ();
            var sources = new Gee.ArrayList<UObject> ();
            sources.add (target);
            var disk = disk_block (target);
            if (disk != null) {
                sources.add (disk);
                foreach (var p in client.partitions (disk)) {
                    sources.add (p);
                    var c = client.cleartext (p);
                    if (c != null) sources.add (c);
                }
            }
            foreach (var s in sources) {
                foreach (var job in client.jobs_for (s)) {
                    if (seen.contains (job.path)) continue;
                    seen.add (job.path);
                    jobs_box.append (job_row (job));
                }
            }
            jobs_box.visible = seen.size > 0;
        }

        private Widget job_row (UObject job) {
            var box = new Box (Orientation.VERTICAL, 4);
            box.add_css_class ("disks-job");
            var top = new Box (Orientation.HORIZONTAL, 8);
            var title = new Label (operation_name (job.str (IFACE_JOB, "Operation")));
            title.xalign = 0;
            title.hexpand = true;
            top.append (title);
            var detail = new Label ("");
            detail.add_css_class ("dim-label");
            detail.add_css_class ("caption");
            top.append (detail);
            if (job.flag (IFACE_JOB, "Cancelable")) {
                var cancel = new Button.from_icon_name ("process-stop-symbolic");
                cancel.tooltip_text = _("Cancel");
                cancel.add_css_class ("flat");
                cancel.clicked.connect (() => run_call.begin (job, IFACE_JOB, "Cancel", new Variant ("(@a{sv})", empty_options ())));
                top.append (cancel);
            }
            box.append (top);
            var bar = new ProgressBar ();
            if (job.flag (IFACE_JOB, "ProgressValid")) {
                bar.fraction = job.dbl (IFACE_JOB, "Progress");
                var parts = new string[0];
                uint64 rate = job.u64 (IFACE_JOB, "Rate");
                if (rate > 0) parts += Format.rate (rate);
                uint64 end = job.u64 (IFACE_JOB, "ExpectedEndTime");
                int64 now = get_real_time ();
                if (end > (uint64) now) parts += _("%s left").printf (Format.duration ((int64) ((end - (uint64) now) / 1000000)));
                detail.label = string.joinv (", ", parts);
            } else {
                bar.pulse ();
            }
            box.append (bar);
            return box;
        }

        private string operation_name (string op) {
            switch (op) {
                case "format-mkfs": return _("Formatting");
                case "format-erase": return _("Erasing");
                case "partition-create": return _("Creating Partition");
                case "partition-delete": return _("Deleting Partition");
                case "partition-modify": return _("Modifying Partition");
                case "filesystem-mount": return _("Mounting");
                case "filesystem-unmount": return _("Unmounting");
                case "filesystem-check": return _("Checking Filesystem");
                case "filesystem-repair": return _("Repairing Filesystem");
                case "filesystem-resize": case "partition-resize": return _("Resizing");
                case "encrypted-unlock": return _("Unlocking");
                case "encrypted-lock": return _("Locking");
                case "encrypted-modify": return _("Changing Passphrase");
                case "ata-smart-selftest": case "nvme-selftest": return _("Running Self-Test");
                case "drive-eject": return _("Ejecting");
                case "cleanup": return _("Cleaning Up");
                default: return op;
            }
        }

        private void show_error (string title, string message) {
            new NoticeDialog (app, title, message).present ();
        }

        private async void run_call (UObject target, string iface, string method, Variant parameters) {
            try {
                yield target.call (iface, method, parameters, int.MAX);
            } catch (Error e) {
                show_error (_("The Operation Failed"), describe_error (e));
            }
        }

        private async void mount (UObject block) {
            try {
                yield block.call (IFACE_FILESYSTEM, "Mount", new Variant ("(@a{sv})", empty_options ()));
            } catch (Error e) {
                show_error (_("Could Not Mount"), describe_error (e));
            }
        }

        private async void lock_volume (UObject part, UObject clear_obj) {
            try {
                if (clear_obj.has (IFACE_FILESYSTEM) && clear_obj.mount_points ().length > 0) {
                    yield clear_obj.call (IFACE_FILESYSTEM, "Unmount", new Variant ("(@a{sv})", empty_options ()));
                }
                if (clear_obj.has (IFACE_SWAP) && clear_obj.flag (IFACE_SWAP, "Active")) {
                    yield clear_obj.call (IFACE_SWAP, "Stop", new Variant ("(@a{sv})", empty_options ()));
                }
                yield part.call (IFACE_ENCRYPTED, "Lock", new Variant ("(@a{sv})", empty_options ()));
            } catch (Error e) {
                show_error (_("Could Not Lock"), describe_error (e));
            }
        }

        private void confirm_delete (UObject part) {
            string label = part.str (IFACE_BLOCK, "IdLabel");
            var dlg = new ConfirmDialog (app, _("Delete Partition?"), "user-trash-symbolic",
                _("All data on %s (%s) will be lost.").printf (label != "" ? label : part.device (), Format.size (part.u64 (IFACE_PARTITION, "Size"))),
                _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    volume_path = null;
                    run_call.begin (part, IFACE_PARTITION, "Delete", new Variant ("(@a{sv})", options ({ "tear-down" }, { new Variant.boolean (true) })));
                }
            });
            dlg.present ();
        }

        private async void check_filesystem (UObject block, bool repair) {
            if (repair) {
                var dlg = new ConfirmDialog (app, _("Repair Filesystem?"), "applications-engineering-symbolic",
                    _("Repairing fixes errors but can lose damaged files. Make a backup first if the data is important."),
                    _("Repair"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
                dlg.transient_for = this;
                bool go = false;
                SourceFunc cb = check_filesystem.callback;
                dlg.response.connect ((r) => {
                    go = r == ConfirmDialog.Response.PRIMARY;
                    Idle.add ((owned) cb);
                });
                dlg.present ();
                yield;
                if (!go) return;
            }
            try {
                var reply = yield block.call (IFACE_FILESYSTEM, repair ? "Repair" : "Check", new Variant ("(@a{sv})", empty_options ()), int.MAX);
                bool ok = reply.get_child_value (0).get_boolean ();
                string title, text;
                if (repair) {
                    title = ok ? _("Filesystem Repaired") : _("Repair Incomplete");
                    text = ok ? _("The filesystem was repaired.") : _("Some errors could not be fixed.");
                } else {
                    title = ok ? _("No Problems Found") : _("Problems Found");
                    text = ok ? _("The filesystem is in good shape.") : _("The filesystem has errors. Use Repair Filesystem to fix them.");
                }
                new NoticeDialog (app, title, text).present ();
            } catch (Error e) {
                show_error (repair ? _("Could Not Repair") : _("Could Not Check"), describe_error (e));
            }
        }

        private void take_ownership (UObject block) {
            var dlg = new ConfirmDialog (app, _("Take Ownership?"), "avatar-default-symbolic",
                _("All files on this volume will belong to you."), _("Take Ownership"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    run_call.begin (block, IFACE_FILESYSTEM, "TakeOwnership", new Variant ("(@a{sv})", options ({ "recursive" }, { new Variant.boolean (true) })));
                }
            });
            dlg.present ();
        }

        private async void tear_down (UObject? disk) throws Error {
            if (disk == null) return;
            var blocks = new Gee.ArrayList<UObject> ();
            blocks.add (disk);
            foreach (var p in client.partitions (disk)) blocks.add (p);
            foreach (var b in blocks) {
                if (b.has (IFACE_ENCRYPTED)) {
                    var c = client.cleartext (b);
                    if (c != null) {
                        if (c.has (IFACE_FILESYSTEM) && c.mount_points ().length > 0) yield c.call (IFACE_FILESYSTEM, "Unmount", new Variant ("(@a{sv})", empty_options ()));
                        yield b.call (IFACE_ENCRYPTED, "Lock", new Variant ("(@a{sv})", empty_options ()));
                    }
                }
                if (b.has (IFACE_FILESYSTEM) && b.mount_points ().length > 0) yield b.call (IFACE_FILESYSTEM, "Unmount", new Variant ("(@a{sv})", empty_options ()));
                if (b.has (IFACE_SWAP) && b.flag (IFACE_SWAP, "Active")) yield b.call (IFACE_SWAP, "Stop", new Variant ("(@a{sv})", empty_options ()));
            }
        }

        private async void eject (UObject drive, UObject? disk, bool power_off) {
            try {
                yield tear_down (disk);
                if (power_off) yield drive.call (IFACE_DRIVE, "PowerOff", new Variant ("(@a{sv})", empty_options ()));
                else yield drive.call (IFACE_DRIVE, "Eject", new Variant ("(@a{sv})", empty_options ()));
            } catch (Error e) {
                show_error (power_off ? _("Could Not Remove the Drive") : _("Could Not Eject"), describe_error (e));
            }
        }

        private async void detach (UObject loop) {
            try {
                yield tear_down (loop);
                yield loop.call (IFACE_LOOP, "Delete", new Variant ("(@a{sv})", empty_options ()));
                selected_path = null;
            } catch (Error e) {
                show_error (_("Could Not Detach"), describe_error (e));
            }
        }
    }
}
