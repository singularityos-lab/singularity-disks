using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Disks {

    public static Gtk.Window? dialog_parent (Gtk.Application app, Gtk.Window dialog) {
        foreach (var w in app.get_windows ()) {
            if (w != dialog && w.visible) return w;
        }
        return null;
    }

    public class FormDialog : AppDialog {
        protected Box body;
        protected Label error_label;
        protected Button primary;
        protected Spinner spinner;
        protected Button cancel_button;
        private ScrolledWindow scroll;


        public FormDialog (Gtk.Application app, string title, string action, bool destructive = false) {
            base (app, true);
            set_title (title);
            set_default_size (520, -1);
            transient_for = dialog_parent (app, this);
            body = new Box (Orientation.VERTICAL, 12);
            body.margin_top = 8;
            body.margin_start = 20;
            body.margin_end = 20;
            scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.max_content_height = 520;
            scroll.child = body;
            content_box.append (scroll);
            error_label = new Label ("");
            error_label.add_css_class ("error");
            error_label.wrap = true;
            error_label.xalign = 0;
            error_label.visible = false;
            error_label.margin_start = 20;
            error_label.margin_end = 20;
            error_label.margin_top = 8;
            content_box.append (error_label);
            var actions = new Box (Orientation.HORIZONTAL, 8);
            actions.margin_top = 16;
            actions.margin_bottom = 16;
            actions.margin_start = 20;
            actions.margin_end = 20;
            spinner = new Spinner ();
            spinner.visible = false;
            actions.append (spinner);
            var spacer = new Box (Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            actions.append (spacer);
            cancel_button = new Button.with_label (_("Cancel"));
            cancel_button.clicked.connect (() => close_dialog ());
            set_cancel_button (cancel_button);
            primary = new Button.with_label (action);
            primary.add_css_class (destructive ? "destructive-action" : "suggested-action");
            primary.clicked.connect (start);
            actions.append (cancel_button);
            actions.append (primary);
            content_box.append (actions);
        }

        protected Box row (string label, Widget widget) {
            var box = new Box (Orientation.HORIZONTAL, 12);
            var l = new Label (label);
            l.xalign = 0;
            l.hexpand = true;
            l.valign = Align.CENTER;
            box.append (l);
            widget.valign = Align.CENTER;
            box.append (widget);
            body.append (box);
            return box;
        }

        protected void fail (string message) {
            int min, nat;
            body.measure (Orientation.VERTICAL, body.get_width (), out min, out nat, null, null);
            scroll.min_content_height = int.min (nat, 520);
            error_label.label = message;
            error_label.visible = true;
            spinner.stop ();
            spinner.visible = false;
            primary.sensitive = true;
            cancel_button.sensitive = true;
        }

        protected virtual string? validate () {
            return null;
        }

        protected virtual async void perform () throws Error {
        }

        private void start () {
            string? problem = validate ();
            if (problem != null) {
                fail (problem);
                return;
            }
            error_label.visible = false;
            primary.sensitive = false;
            cancel_button.sensitive = false;
            spinner.visible = true;
            spinner.start ();
            perform.begin ((obj, res) => {
                try {
                    perform.end (res);
                    close_dialog ();
                } catch (Error e) {
                    fail (DisksWindow.describe_error (e));
                }
            });
        }
    }

    public class FsChooser : Box {
        private Gee.List<FsOption> fs_options;
        private CheckButton[] buttons = {};
        private Entry name_entry;
        private PasswordEntry pass1;
        private PasswordEntry pass2;
        private Box pass_box;
        public signal void changed ();

        public FsChooser (string preselect = "ext4") {
            Object (orientation: Orientation.VERTICAL, spacing: 10);
            name_entry = new Entry ();
            name_entry.placeholder_text = _("Volume Name (optional)");
            name_entry.changed.connect (() => changed ());
            append (name_entry);
            var list = new Grid ();
            list.column_spacing = 12;
            list.row_spacing = 2;
            list.column_homogeneous = true;
            list.add_css_class ("disks-fs-list");
            int index = 0;
            fs_options = Format.options ();
            CheckButton? group = null;
            foreach (var option in fs_options) {
                var check = new CheckButton ();
                var labels = new Box (Orientation.VERTICAL, 0);
                var title = new Label (option.label);
                title.xalign = 0;
                var detail = new Label (option.detail);
                detail.xalign = 0;
                detail.wrap = true;
                detail.add_css_class ("dim-label");
                detail.add_css_class ("caption");
                labels.append (title);
                labels.append (detail);
                check.child = labels;
                if (group != null) check.group = group; else group = check;
                check.active = option.id == preselect;
                check.toggled.connect (() => {
                    sync ();
                    changed ();
                });
                buttons += check;
                list.attach (check, index % 2, index / 2, 1, 1);
                index++;
            }
            append (list);
            pass_box = new Box (Orientation.VERTICAL, 6);
            pass1 = new PasswordEntry ();
            pass1.show_peek_icon = true;
            pass1.placeholder_text = _("Passphrase");
            pass2 = new PasswordEntry ();
            pass2.show_peek_icon = true;
            pass2.placeholder_text = _("Confirm Passphrase");
            pass1.changed.connect (() => changed ());
            pass2.changed.connect (() => changed ());
            var warn = new Label (_("If you lose the passphrase, the data cannot be recovered."));
            warn.add_css_class ("dim-label");
            warn.add_css_class ("caption");
            warn.wrap = true;
            warn.xalign = 0;
            pass_box.append (pass1);
            pass_box.append (pass2);
            pass_box.append (warn);
            append (pass_box);
            sync ();
        }

        private void sync () {
            var option = selected ();
            bool reveal = option.encrypted && !pass_box.visible;
            pass_box.visible = option.encrypted;
            if (reveal && get_mapped ()) {
                Idle.add (() => {
                    pass1.grab_focus ();
                    return Source.REMOVE;
                });
            }
            name_entry.sensitive = option.label_max > 0;
            if (option.label_max > 0) name_entry.max_length = option.label_max;
        }

        public FsOption selected () {
            for (int i = 0; i < buttons.length; i++) if (buttons[i].active) return fs_options[i];
            return fs_options[0];
        }

        public string volume_name () {
            return name_entry.text.strip ();
        }

        public string? problem () {
            var option = selected ();
            if (option.encrypted) {
                if (pass1.text == "") return _("Enter a passphrase.");
                if (pass1.text != pass2.text) return _("The passphrases do not match.");
            }
            return null;
        }

        public Variant format_options (bool erase) {
            var option = selected ();
            string[] keys = { "tear-down", "update-partition-type" };
            Variant[] values = { new Variant.boolean (true), new Variant.boolean (true) };
            if (volume_name () != "" && option.label_max > 0) {
                keys += "label";
                values += new Variant.string (volume_name ());
            }
            if (erase) {
                keys += "erase";
                values += new Variant.string ("zero");
            }
            if (option.fs_type == "ext4" || option.fs_type == "btrfs" || option.fs_type == "xfs") {
                keys += "take-ownership";
                values += new Variant.boolean (true);
            }
            if (option.encrypted) {
                keys += "encrypt.passphrase";
                values += new Variant.string (pass1.text);
                keys += "encrypt.type";
                values += new Variant.string ("luks2");
            }
            return options (keys, values);
        }
    }

    public class FormatVolumeDialog : FormDialog {
        private UDisksClient client;
        private UObject target;
        private FsChooser chooser;
        private Switch erase;

        public FormatVolumeDialog (DisksApp app, UDisksClient client, UObject target) {
            base (app, _("Format Volume"), _("Format"), true);
            this.client = client;
            this.target = target;
            string current = target.str (IFACE_BLOCK, "IdLabel");
            chooser = new FsChooser (target.str (IFACE_BLOCK, "IdType") == "vfat" ? "vfat" : "ext4");
            body.append (chooser);
            erase = new Switch ();
            row (_("Erase Everything (Slow)"), erase);
            var hint = new Label (_("All data on %s (%s) will be lost.").printf (current != "" ? current : target.device (), Format.size (target.u64 (IFACE_BLOCK, "Size"))));
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class ("dim-label");
            body.append (hint);
        }

        protected override string? validate () {
            return chooser.problem ();
        }

        protected override async void perform () throws Error {
            var option = chooser.selected ();
            var opts = chooser.format_options (erase.active);
            string missing = "";
            if (option.fs_type != "empty" && !(yield client.can_format (option.fs_type, out missing))) {
                throw new IOError.NOT_SUPPORTED (_("Formatting as %s needs the %s program, which is not installed.").printf (option.label, missing));
            }
            yield target.call (IFACE_BLOCK, "Format", new Variant ("(s@a{sv})", option.fs_type, opts), int.MAX);
        }
    }

    public class FormatDiskDialog : FormDialog {
        private UObject disk;
        private DropDown scheme;
        private Switch erase;

        public FormatDiskDialog (DisksApp app, UObject disk) {
            base (app, _("Format Disk"), _("Format"), true);
            this.disk = disk;
            scheme = new DropDown.from_strings ({
                _("GPT (modern computers, disks over 2 TB)"), _("MBR (older computers and devices)"), _("No Partitioning (Empty)")
            });
            row (_("Partitioning"), scheme);
            erase = new Switch ();
            row (_("Erase Everything (Slow)"), erase);
            var hint = new Label (_("All data on %s (%s) will be lost, including every partition.").printf (disk.device (), Format.size (disk.u64 (IFACE_BLOCK, "Size"))));
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class ("dim-label");
            body.append (hint);
        }

        protected override async void perform () throws Error {
            string[] types = { "gpt", "dos", "empty" };
            string type = types[scheme.selected];
            string[] keys = { "tear-down" };
            Variant[] values = { new Variant.boolean (true) };
            if (erase.active) {
                keys += "erase";
                values += new Variant.string ("zero");
            }
            yield disk.call (IFACE_BLOCK, "Format", new Variant ("(s@a{sv})", type, options (keys, values)), int.MAX);
        }
    }

    public class CreatePartitionDialog : FormDialog {
        private UDisksClient client;
        private UObject table;
        private Segment free;
        private bool dos;
        private SpinButton size;
        private DropDown? kind = null;
        private Entry? name_entry = null;
        private FsChooser chooser;

        public CreatePartitionDialog (DisksApp app, UDisksClient client, UObject table, Segment free) {
            base (app, _("Create Partition"), _("Create"));
            this.client = client;
            this.table = table;
            this.free = free;
            dos = table.str (IFACE_TABLE, "Type") == "dos";
            uint64 max_mb = free.size / (1000 * 1000);
            size = new SpinButton.with_range (1, double.max (1, max_mb), 1);
            size.value = max_mb;
            size.digits = 0;
            var size_box = new Box (Orientation.HORIZONTAL, 6);
            size_box.append (size);
            size_box.append (new Label ("MB"));
            row (_("Size (up to %s)").printf (Format.size (free.size)), size_box);
            var free_after = new Label ("");
            free_after.add_css_class ("dim-label");
            free_after.xalign = 0;
            size.value_changed.connect (() => {
                uint64 used = (uint64) size.value * 1000 * 1000;
                free_after.label = _("Free space after: %s").printf (Format.size (free.size > used ? free.size - used : 0));
            });
            size.value_changed ();
            body.append (free_after);
            if (dos && !free.logical) {
                kind = new DropDown.from_strings ({ _("Primary"), _("Extended (holds more partitions)") });
                row (_("Partition Kind"), kind);
            }
            if (!dos) {
                name_entry = new Entry ();
                name_entry.placeholder_text = _("Partition Name (optional)");
                name_entry.max_length = 36;
                body.append (name_entry);
            }
            chooser = new FsChooser ("ext4");
            body.append (chooser);
            if (kind != null) kind.notify["selected"].connect (() => chooser.visible = kind.selected == 0);
        }

        private string part_type () {
            if (free.logical) return "logical";
            return kind != null && kind.selected == 1 ? "extended" : "primary";
        }

        protected override string? validate () {
            if (part_type () == "extended") return null;
            return chooser.problem ();
        }

        protected override async void perform () throws Error {
            uint64 bytes = uint64.min (free.size, (uint64) size.value * 1000 * 1000);
            string part_name = name_entry != null ? name_entry.text.strip () : "";
            string type = part_type ();
            var option = chooser.selected ();
            Variant part_opts = dos ? options ({ "partition-type" }, { new Variant.string (type) }) : empty_options ();
            if (type == "extended" || option.fs_type == "empty") {
                yield table.call (IFACE_TABLE, "CreatePartition",
                    new Variant ("(ttss@a{sv})", free.offset, bytes, type == "extended" ? "0x05" : "", part_name, part_opts), int.MAX);
                return;
            }
            string missing = "";
            if (!(yield client.can_format (option.fs_type, out missing))) {
                throw new IOError.NOT_SUPPORTED (_("Formatting as %s needs the %s program, which is not installed.").printf (option.label, missing));
            }
            yield table.call (IFACE_TABLE, "CreatePartitionAndFormat",
                new Variant ("(ttss@a{sv}s@a{sv})", free.offset, bytes, "", part_name, part_opts, option.fs_type,
                    chooser.format_options (false)), int.MAX);
        }
    }

    public class EditPartitionDialog : FormDialog {
        private UObject partition;
        private bool dos;
        private string current_type;
        private string[] ids = {};
        private DropDown type;
        private Entry? name_entry = null;
        private uint64 flags;
        private CheckButton[] flag_checks = {};
        private uint64[] flag_bits = {};

        public EditPartitionDialog (DisksApp app, UObject table, UObject partition) {
            base (app, _("Edit Partition"), _("Save"));
            this.partition = partition;
            dos = table.str (IFACE_TABLE, "Type") == "dos";
            current_type = partition.str (IFACE_PARTITION, "Type");
            ids = dos ? Format.dos_types () : Format.gpt_types ();
            string[] names = {};
            bool found = false;
            foreach (string id in ids) {
                names += dos ? Format.dos_type_name (id) : Format.gpt_type_name (id);
                if (same_type (id, current_type)) found = true;
            }
            if (!found && current_type != "") {
                ids += current_type;
                names += dos ? Format.dos_type_name (current_type) : Format.gpt_type_name (current_type);
            }
            type = new DropDown.from_strings (names);
            for (int i = 0; i < ids.length; i++) if (same_type (ids[i], current_type)) type.selected = i;
            row (_("Type"), type);
            if (!dos) {
                name_entry = new Entry ();
                name_entry.text = partition.str (IFACE_PARTITION, "Name");
                name_entry.placeholder_text = _("Partition Name");
                name_entry.max_length = 36;
                row (_("Name"), name_entry);
            }
            flags = partition.u64 (IFACE_PARTITION, "Flags");
            if (dos) {
                add_flag (_("Bootable"), 0x80);
            } else {
                add_flag (_("System Partition"), 1);
                add_flag (_("Hide from Firmware"), 2);
                add_flag (_("Legacy BIOS Bootable"), 4);
            }
        }

        private static bool same_type (string a, string b) {
            string x = a.down (), y = b.down ();
            if (x.has_prefix ("0x")) x = x.substring (2);
            if (y.has_prefix ("0x")) y = y.substring (2);
            while (x.length > 1 && x.has_prefix ("0")) x = x.substring (1);
            while (y.length > 1 && y.has_prefix ("0")) y = y.substring (1);
            return x == y;
        }

        private void add_flag (string label, uint64 bit) {
            var check = new CheckButton.with_label (label);
            check.active = (flags & bit) != 0;
            body.append (check);
            flag_checks += check;
            flag_bits += bit;
        }

        protected override async void perform () throws Error {
            string new_type = ids[type.selected];
            if (!same_type (new_type, current_type)) {
                yield partition.call (IFACE_PARTITION, "SetType", new Variant ("(s@a{sv})", new_type, empty_options ()));
            }
            if (name_entry != null && name_entry.text.strip () != partition.str (IFACE_PARTITION, "Name")) {
                yield partition.call (IFACE_PARTITION, "SetName", new Variant ("(s@a{sv})", name_entry.text.strip (), empty_options ()));
            }
            uint64 new_flags = flags;
            for (int i = 0; i < flag_checks.length; i++) {
                if (flag_checks[i].active) new_flags |= flag_bits[i];
                else new_flags &= ~flag_bits[i];
            }
            if (new_flags != flags) {
                yield partition.call (IFACE_PARTITION, "SetFlags", new Variant ("(t@a{sv})", new_flags, empty_options ()));
            }
        }
    }

    public class LabelDialog : FormDialog {
        private UObject fs;
        private Entry entry;

        public LabelDialog (DisksApp app, UObject fs) {
            base (app, _("Rename Filesystem"), _("Rename"));
            this.fs = fs;
            entry = new Entry ();
            entry.text = fs.str (IFACE_BLOCK, "IdLabel");
            entry.placeholder_text = _("Volume Name");
            entry.hexpand = true;
            body.append (entry);
            entry.activate.connect (() => primary.activate ());
            map.connect (() => {
                entry.grab_focus ();
                entry.select_region (0, -1);
            });
        }

        protected override async void perform () throws Error {
            yield fs.call (IFACE_FILESYSTEM, "SetLabel", new Variant ("(s@a{sv})", entry.text.strip (), empty_options ()));
        }
    }

    public class UnlockDialog : FormDialog {
        private UObject encrypted;
        private PasswordEntry pass;

        public UnlockDialog (DisksApp app, UObject encrypted) {
            base (app, _("Unlock Volume"), _("Unlock"));
            this.encrypted = encrypted;
            var hint = new Label (_("Enter the passphrase for %s.").printf (encrypted.device ()));
            hint.xalign = 0;
            hint.wrap = true;
            body.append (hint);
            pass = new PasswordEntry ();
            pass.show_peek_icon = true;
            pass.placeholder_text = _("Passphrase");
            body.append (pass);
            pass.activate.connect (() => primary.activate ());
            map.connect (() => pass.grab_focus ());
        }

        protected override async void perform () throws Error {
            yield encrypted.call (IFACE_ENCRYPTED, "Unlock", new Variant ("(s@a{sv})", pass.text, empty_options ()));
        }
    }

    public class PassphraseDialog : FormDialog {
        private UObject encrypted;
        private PasswordEntry current;
        private PasswordEntry p1;
        private PasswordEntry p2;

        public PassphraseDialog (DisksApp app, UObject encrypted) {
            base (app, _("Change Passphrase"), _("Change"));
            this.encrypted = encrypted;
            current = new PasswordEntry ();
            current.show_peek_icon = true;
            current.placeholder_text = _("Current Passphrase");
            p1 = new PasswordEntry ();
            p1.show_peek_icon = true;
            p1.placeholder_text = _("New Passphrase");
            p2 = new PasswordEntry ();
            p2.show_peek_icon = true;
            p2.placeholder_text = _("Confirm New Passphrase");
            body.append (current);
            body.append (p1);
            body.append (p2);
        }

        protected override string? validate () {
            if (p1.text == "") return _("Enter a new passphrase.");
            if (p1.text != p2.text) return _("The new passphrases do not match.");
            return null;
        }

        protected override async void perform () throws Error {
            yield encrypted.call (IFACE_ENCRYPTED, "ChangePassphrase", new Variant ("(ss@a{sv})", current.text, p1.text, empty_options ()));
        }
    }

    public class ResizeDialog : FormDialog {
        private UObject partition;
        private uint64 current;
        private SpinButton size;
        private bool can_shrink = true;
        private bool can_grow = true;

        public ResizeDialog (DisksApp app, UDisksClient client, UObject partition, uint64 max_size) {
            base (app, _("Resize"), _("Resize"));
            this.partition = partition;
            current = partition.u64 (IFACE_PARTITION, "Size");
            string fs_type = partition.str (IFACE_BLOCK, "IdType");
            var info = new Label ("");
            info.wrap = true;
            info.xalign = 0;
            info.add_css_class ("dim-label");
            body.append (info);
            size = new SpinButton.with_range (1, max_size / (1000.0 * 1000.0), 1);
            size.value = current / (1000.0 * 1000.0);
            var box = new Box (Orientation.HORIZONTAL, 6);
            box.append (size);
            box.append (new Label ("MB"));
            row (_("New Size (up to %s)").printf (Format.size (max_size)), box);
            check_modes.begin (client, fs_type, info);
        }

        private async void check_modes (UDisksClient client, string fs_type, Label info) {
            info.label = _("Shrinking needs free space inside the filesystem. Make a backup first.");
            if (fs_type == "crypto_LUKS") {
                can_shrink = false;
                info.label = _("Encrypted partitions can only grow. Unlock the volume afterwards to use the new space.");
                return;
            }
            if (fs_type == "") {
                info.label = _("Only the partition is resized.");
                return;
            }
            var manager = client.lookup ("/org/freedesktop/UDisks2/Manager");
            if (manager == null) return;
            try {
                var reply = yield manager.call (IFACE_MANAGER, "CanResize", new Variant ("(s)", fs_type));
                bool available;
                uint64 mode;
                string missing = "";
                reply.get ("((bts))", out available, out mode, out missing);
                if (!available) {
                    can_shrink = can_grow = false;
                    primary.sensitive = false;
                    info.label = missing != "" ? _("Resizing %s needs the %s program.").printf (Format.filesystem_name (fs_type), missing)
                        : _("%s cannot be resized.").printf (Format.filesystem_name (fs_type));
                    return;
                }
                bool mounted = partition.has (IFACE_FILESYSTEM) && partition.mount_points ().length > 0;
                can_shrink = (mode & (mounted ? 8 : 2)) != 0;
                can_grow = (mode & (mounted ? 16 : 4)) != 0;
                if (!can_shrink && !can_grow) {
                    primary.sensitive = false;
                    info.label = _("Unmount %s to resize it.").printf (Format.filesystem_name (fs_type));
                } else if (!can_shrink) {
                    info.label = mounted && (mode & 2) != 0
                        ? _("Unmount the volume to make it smaller. While mounted it can only grow.")
                        : _("%s can only grow.").printf (Format.filesystem_name (fs_type));
                }
            } catch (Error e) {
            }
        }

        protected override string? validate () {
            uint64 target = (uint64) (size.value * 1000 * 1000);
            if (target < current && !can_shrink) return _("This filesystem cannot be made smaller.");
            if (target > current && !can_grow) return _("This filesystem cannot be made larger.");
            return null;
        }

        protected override async void perform () throws Error {
            uint64 target = (uint64) (size.value * 1000 * 1000);
            bool has_fs = partition.has (IFACE_FILESYSTEM);
            if (target < current) {
                if (has_fs) yield partition.call (IFACE_FILESYSTEM, "Resize", new Variant ("(t@a{sv})", target, empty_options ()), int.MAX);
                yield partition.call (IFACE_PARTITION, "Resize", new Variant ("(t@a{sv})", target, empty_options ()), int.MAX);
            } else {
                yield partition.call (IFACE_PARTITION, "Resize", new Variant ("(t@a{sv})", target, empty_options ()), int.MAX);
                if (has_fs) yield partition.call (IFACE_FILESYSTEM, "Resize", new Variant ("(t@a{sv})", (uint64) 0, empty_options ()), int.MAX);
            }
        }
    }

    public class MountOptionsDialog : FormDialog {
        private UObject fs;
        private Variant? existing = null;
        private Switch mount_at_start;
        private Entry dir_entry;
        private Entry opts_entry;

        public MountOptionsDialog (DisksApp app, UObject fs) {
            base (app, _("Mount Options"), _("Save"));
            this.fs = fs;
            var config = fs.prop (IFACE_BLOCK, "Configuration");
            if (config != null) {
                for (size_t i = 0; i < config.n_children (); i++) {
                    var item = config.get_child_value (i);
                    if (item.get_child_value (0).get_string () == "fstab") existing = item;
                }
            }
            string dir = "", opts = "defaults,nofail", uuid = fs.str (IFACE_BLOCK, "IdUUID");
            if (existing != null) {
                var dict = existing.get_child_value (1);
                var d = dict.lookup_value ("dir", null);
                if (d != null) dir = UObject.bytestring (d);
                var o = dict.lookup_value ("opts", null);
                if (o != null) opts = UObject.bytestring (o);
            } else {
                string label = fs.str (IFACE_BLOCK, "IdLabel");
                dir = "/mnt/" + (label != "" ? label.replace (" ", "_") : (uuid != "" ? uuid : "disk"));
            }
            mount_at_start = new Switch ();
            mount_at_start.active = existing != null;
            row (_("Mount at Startup"), mount_at_start);
            dir_entry = new Entry ();
            dir_entry.text = dir;
            dir_entry.hexpand = true;
            row (_("Mount Point"), dir_entry);
            opts_entry = new Entry ();
            opts_entry.text = opts;
            opts_entry.hexpand = true;
            row (_("Options"), opts_entry);
            var hint = new Label (_("Stored in /etc/fstab. \"nofail\" keeps the computer starting when the disk is missing."));
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            body.append (hint);
            mount_at_start.notify["active"].connect (sync);
            sync ();
        }

        private void sync () {
            dir_entry.sensitive = mount_at_start.active;
            opts_entry.sensitive = mount_at_start.active;
        }

        protected override string? validate () {
            if (mount_at_start.active && !dir_entry.text.strip ().has_prefix ("/")) return _("The mount point must be an absolute path.");
            return null;
        }

        protected override async void perform () throws Error {
            string uuid = fs.str (IFACE_BLOCK, "IdUUID");
            var builder = new VariantBuilder (new VariantType ("a{sv}"));
            builder.add ("{sv}", "fsname", new Variant.bytestring (uuid != "" ? "UUID=" + uuid : fs.device ()));
            builder.add ("{sv}", "dir", new Variant.bytestring (dir_entry.text.strip ()));
            builder.add ("{sv}", "type", new Variant.bytestring (fs.str (IFACE_BLOCK, "IdType")));
            builder.add ("{sv}", "opts", new Variant.bytestring (opts_entry.text.strip () != "" ? opts_entry.text.strip () : "defaults"));
            builder.add ("{sv}", "freq", new Variant.int32 (0));
            builder.add ("{sv}", "passno", new Variant.int32 (0));
            var item = new Variant ("(s@a{sv})", "fstab", builder.end ());
            if (!mount_at_start.active) {
                if (existing != null) yield fs.call (IFACE_BLOCK, "RemoveConfigurationItem", new Variant ("(@(sa{sv})@a{sv})", existing, empty_options ()));
                return;
            }
            if (existing != null) {
                yield fs.call (IFACE_BLOCK, "UpdateConfigurationItem", new Variant ("(@(sa{sv})@(sa{sv})@a{sv})", existing, item, empty_options ()));
            } else {
                yield fs.call (IFACE_BLOCK, "AddConfigurationItem", new Variant ("(@(sa{sv})@a{sv})", item, empty_options ()));
            }
        }
    }

    public class DriveSettingsDialog : FormDialog {
        private UObject drive;
        private DropDown standby_drop;
        private Switch cache_switch;
        private bool cache_known = false;
        private const int[] STANDBY = { 0, 60, 120, 240, 241, 242 };

        public DriveSettingsDialog (DisksApp app, UObject drive) {
            base (app, _("Drive Settings"), _("Save"));
            this.drive = drive;
            var config = drive.prop (IFACE_DRIVE, "Configuration");
            int standby = -1;
            bool cache = true;
            if (config != null) {
                var s = config.lookup_value ("ata-pm-standby", null);
                if (s != null) standby = s.get_int32 ();
                var c = config.lookup_value ("ata-write-cache-enabled", null);
                if (c != null) {
                    cache_known = true;
                    cache = c.get_boolean ();
                }
            }
            standby_drop = new DropDown.from_strings ({ _("Never"), _("5 minutes"), _("10 minutes"), _("20 minutes"), _("30 minutes"), _("1 hour") });
            for (int i = 0; i < STANDBY.length; i++) if (STANDBY[i] == standby) standby_drop.selected = i;
            row (_("Spin Down When Idle"), standby_drop);
            cache_switch = new Switch ();
            cache_switch.active = cache;
            row (_("Write Cache"), cache_switch);
            standby_drop.sensitive = drive.flag (IFACE_ATA, "PmSupported");
            cache_switch.sensitive = drive.flag (IFACE_ATA, "WriteCacheSupported");
            if (!drive.has (IFACE_ATA) || (!standby_drop.sensitive && !cache_switch.sensitive)) {
                standby_drop.sensitive = false;
                cache_switch.sensitive = false;
                var note = new Label (_("This drive does not support these settings."));
                note.add_css_class ("dim-label");
                note.xalign = 0;
                body.append (note);
                primary.sensitive = false;
            }
            var hint = new Label (_("Settings are applied now and every time the drive is connected."));
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            body.append (hint);
        }

        protected override async void perform () throws Error {
            var builder = new VariantBuilder (new VariantType ("a{sv}"));
            if (standby_drop.sensitive) builder.add ("{sv}", "ata-pm-standby", new Variant.int32 (STANDBY[standby_drop.selected]));
            if (cache_switch.sensitive && (cache_known || !cache_switch.active)) builder.add ("{sv}", "ata-write-cache-enabled", new Variant.boolean (cache_switch.active));
            yield drive.call (IFACE_DRIVE, "SetConfiguration", new Variant ("(@a{sv}@a{sv})", builder.end (), empty_options ()));
        }
    }

    public class NoticeDialog : AppDialog {
        public NoticeDialog (Gtk.Application app, string title, string message) {
            base (app, true);
            transient_for = dialog_parent (app, this);
            set_title (title);
            set_default_size (380, -1);
            var box = new Box (Orientation.VERTICAL, 16);
            box.margin_top = 28;
            box.margin_bottom = 24;
            box.margin_start = 32;
            box.margin_end = 32;
            var text = new Label (message);
            text.wrap = true;
            text.justify = Justification.CENTER;
            text.max_width_chars = 40;
            box.append (text);
            var close = new Button.with_label (_("Close"));
            close.add_css_class ("pill");
            close.width_request = 120;
            close.halign = Align.CENTER;
            close.clicked.connect (() => close_dialog ());
            set_cancel_button (close);
            box.append (close);
            content_box.append (box);
        }
    }
}
