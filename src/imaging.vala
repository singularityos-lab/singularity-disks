using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Disks {

    [CCode (cname = "posix_fadvise", cheader_filename = "fcntl.h")]
    private extern int fadvise (int fd, int64 offset, int64 len, int advice);

    public class BlockCopy : Object {
        private const int CHUNK = 4 * 1024 * 1024;
        private int source;
        private int target;
        public uint64 total;
        private uint64 done = 0;
        private int cancelled = 0;
        private string? failure = null;
        private int64 started;

        public signal void progress (uint64 done, uint64 total, double rate);
        public signal void finished (string? error, bool cancelled);

        public BlockCopy (int source, int target, uint64 total) {
            this.source = source;
            this.target = target;
            this.total = total;
        }

        public void cancel () {
            AtomicInt.set (ref cancelled, 1);
        }

        public void start () {
            started = get_monotonic_time ();
            var tick = Timeout.add (250, () => {
                double secs = (get_monotonic_time () - started) / 1000000.0;
                uint64 now = done;
                progress (now, total, secs > 0 ? now / secs : 0);
                return Source.CONTINUE;
            });
            new Thread<void*> ("disks-copy", () => {
                var buffer = new uint8[CHUNK];
                while (AtomicInt.get (ref cancelled) == 0) {
                    ssize_t n = Posix.read (source, buffer, CHUNK);
                    if (n < 0) {
                        if (errno == Posix.EINTR) continue;
                        failure = _("Reading failed: %s").printf (strerror (errno));
                        break;
                    }
                    if (n == 0) break;
                    ssize_t written = 0;
                    while (written < n) {
                        ssize_t w = Posix.write (target, (uint8*) buffer + written, n - written);
                        if (w < 0) {
                            if (errno == Posix.EINTR) continue;
                            failure = _("Writing failed: %s").printf (strerror (errno));
                            break;
                        }
                        written += w;
                    }
                    if (failure != null) break;
                    done += n;
                }
                if (failure == null && AtomicInt.get (ref cancelled) == 0 && Posix.fsync (target) != 0 && errno != Posix.EINVAL) {
                    failure = _("Writing failed: %s").printf (strerror (errno));
                }
                Posix.close (source);
                Posix.close (target);
                Idle.add (() => {
                    Source.remove (tick);
                    double secs = (get_monotonic_time () - started) / 1000000.0;
                    progress (done, total, secs > 0 ? done / secs : 0);
                    finished (failure, AtomicInt.get (ref cancelled) != 0);
                    return Source.REMOVE;
                });
                return null;
            });
        }
    }

    public static async int open_block_fd (UObject block, string method) throws Error {
        UnixFDList? fds;
        var reply = yield block.call_with_fd (IFACE_BLOCK, method, new Variant ("(@a{sv})", empty_options ()), out fds);
        int32 index;
        reply.get ("(h)", out index);
        if (fds == null) throw new IOError.FAILED (_("No file descriptor was returned"));
        return fds.get (index);
    }

    public class ImageDialog : AppDialog {
        private UObject block;
        private bool restore;
        private File? file = null;
        private Label file_label;
        private Label status;
        private Label detail;
        private ProgressBar bar;
        private Button primary;
        private Button cancel;
        private Button choose;
        private BlockCopy? copy = null;
        private bool done = false;

        public ImageDialog (DisksApp app, UObject block, bool restore) {
            base (app, true);
            transient_for = dialog_parent (app, this);
            this.block = block;
            this.restore = restore;
            set_title (restore ? _("Restore Disk Image") : _("Create Disk Image"));
            set_default_size (480, -1);
            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_top = 8;
            box.margin_start = 20;
            box.margin_end = 20;
            box.margin_bottom = 16;
            string name = block.str (IFACE_BLOCK, "IdLabel");
            if (name == "") name = block.device ();
            var intro = new Label (restore
                ? _("Write an image file onto %s (%s). Everything on it will be replaced.").printf (name, Format.size (block.u64 (IFACE_BLOCK, "Size")))
                : _("Save an exact copy of %s (%s) to a file.").printf (name, Format.size (block.u64 (IFACE_BLOCK, "Size"))));
            intro.wrap = true;
            intro.xalign = 0;
            box.append (intro);
            var file_row = new Box (Orientation.HORIZONTAL, 8);
            file_label = new Label (_("No file chosen"));
            file_label.xalign = 0;
            file_label.hexpand = true;
            file_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            file_label.add_css_class ("dim-label");
            file_row.append (file_label);
            choose = new Button.with_label (restore ? _("Choose Image") : _("Choose Location"));
            choose.clicked.connect (pick_file);
            file_row.append (choose);
            box.append (file_row);
            bar = new ProgressBar ();
            bar.visible = false;
            box.append (bar);
            status = new Label ("");
            status.xalign = 0;
            status.wrap = true;
            box.append (status);
            detail = new Label ("");
            detail.xalign = 0;
            detail.add_css_class ("dim-label");
            detail.add_css_class ("caption");
            box.append (detail);
            foreach (var l in new Label[] { status, detail }) {
                l.visible = false;
                l.notify["label"].connect ((obj, spec) => {
                    var label = (Label) obj;
                    label.visible = label.label != "";
                });
            }
            var actions = new Box (Orientation.HORIZONTAL, 8);
            actions.halign = Align.END;
            actions.margin_top = 8;
            cancel = new Button.with_label (_("Cancel"));
            cancel.clicked.connect (() => {
                if (copy != null && !done) copy.cancel ();
                else close_dialog ();
            });
            set_cancel_button (cancel);
            primary = new Button.with_label (restore ? _("Restore") : _("Create"));
            primary.add_css_class (restore ? "destructive-action" : "suggested-action");
            primary.sensitive = false;
            primary.clicked.connect (() => begin.begin ());
            actions.append (cancel);
            actions.append (primary);
            box.append (actions);
            content_box.append (box);
            close_request.connect (() => {
                if (copy != null && !done) {
                    copy.cancel ();
                    return true;
                }
                return false;
            });
        }

        private void pick_file () {
            var dialog = new FileDialog ();
            if (restore) {
                dialog.title = _("Choose Disk Image");
                var filter = new FileFilter ();
                filter.name = _("Disk Images");
                foreach (string s in new string[] { "img", "iso", "raw", "bin" }) filter.add_suffix (s);
                filter.add_mime_type ("application/x-cd-image");
                filter.add_mime_type ("application/x-raw-disk-image");
                var all = new FileFilter ();
                all.name = _("All Files");
                all.add_pattern ("*");
                var filters = new GLib.ListStore (typeof (FileFilter));
                filters.append (filter);
                filters.append (all);
                dialog.filters = filters;
                dialog.open.begin (this, null, (obj, res) => {
                    try {
                        set_file (dialog.open.end (res));
                    } catch (Error e) {
                    }
                });
            } else {
                dialog.title = _("Save Disk Image");
                string label = block.str (IFACE_BLOCK, "IdLabel");
                string stem = label != "" ? label : Path.get_basename (block.device ());
                dialog.initial_name = "%s %s.img".printf (stem, new DateTime.now_local ().format ("%Y-%m-%d %H%M"));
                dialog.save.begin (this, null, (obj, res) => {
                    try {
                        set_file (dialog.save.end (res));
                    } catch (Error e) {
                    }
                });
            }
        }

        private void set_file (File? chosen) {
            if (chosen == null || chosen.get_path () == null) return;
            file = chosen;
            file_label.label = chosen.get_path ();
            file_label.remove_css_class ("dim-label");
            status.label = "";
            status.remove_css_class ("error");
            primary.sensitive = true;
            if (restore) {
                try {
                    var info = chosen.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                    uint64 size = info.get_size ();
                    uint64 capacity = block.u64 (IFACE_BLOCK, "Size");
                    detail.label = _("Image size: %s").printf (Format.size (size));
                    if (size > capacity) {
                        status.label = _("The image is larger than the destination (%s).").printf (Format.size (capacity));
                        status.add_css_class ("error");
                        primary.sensitive = false;
                    } else if (size < capacity) {
                        detail.label += ", " + _("%s at the end will be left unchanged").printf (Format.size (capacity - size));
                    }
                } catch (Error e) {
                    status.label = e.message;
                    primary.sensitive = false;
                }
            }
        }

        private async void begin () {
            primary.sensitive = false;
            choose.sensitive = false;
            status.remove_css_class ("error");
            status.label = _("Preparing");
            int fd_block;
            try {
                fd_block = yield open_block_fd (block, restore ? "OpenForRestore" : "OpenForBackup");
            } catch (Error e) {
                fail (DisksWindow.describe_error (e));
                return;
            }
            string path = file.get_path ();
            int fd_file = restore ? Posix.open (path, Posix.O_RDONLY) : Posix.open (path, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_TRUNC, 0644);
            if (fd_file < 0) {
                Posix.close (fd_block);
                fail (_("Cannot open %s: %s").printf (path, strerror (errno)));
                return;
            }
            uint64 total = restore ? file_size () : block.u64 (IFACE_BLOCK, "Size");
            copy = restore ? new BlockCopy (fd_file, fd_block, total) : new BlockCopy (fd_block, fd_file, total);
            bar.visible = true;
            status.label = restore ? _("Restoring") : _("Copying");
            copy.progress.connect ((done_bytes, all, rate) => {
                bar.fraction = all > 0 ? (double) done_bytes / all : 0;
                string eta = rate > 0 && all > done_bytes ? _(", %s left").printf (Format.duration ((int64) ((all - done_bytes) / rate))) : "";
                detail.label = _("%s of %s, %s").printf (Format.size (done_bytes), Format.size (all), Format.rate (rate)) + eta;
            });
            copy.finished.connect ((error, was_cancelled) => {
                done = true;
                primary.visible = false;
                cancel.label = _("Close");
                if (error != null || was_cancelled) {
                    if (!restore) FileUtils.remove (path);
                    if (was_cancelled) {
                        status.label = restore ? _("Stopped. The destination is now only partly written and may not work.") : _("Stopped. The partial image was removed.");
                    } else {
                        status.label = error;
                        status.add_css_class ("error");
                    }
                    return;
                }
                bar.fraction = 1;
                status.label = restore ? _("The image was restored.") : _("The image was saved.");
            });
            copy.start ();
        }

        private uint64 file_size () {
            try {
                return file.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size ();
            } catch (Error e) {
                return 0;
            }
        }

        private void fail (string message) {
            status.label = message;
            status.add_css_class ("error");
            primary.sensitive = true;
            choose.sensitive = true;
        }
    }

    public class AttachImageDialog : FormDialog {
        private UDisksClient client;
        private File? file = null;
        private Label file_label;
        private Switch read_only;

        public AttachImageDialog (DisksApp app, UDisksClient client) {
            base (app, _("Attach Disk Image"), _("Attach"));
            this.client = client;
            var file_row = new Box (Orientation.HORIZONTAL, 8);
            file_label = new Label (_("No file chosen"));
            file_label.xalign = 0;
            file_label.hexpand = true;
            file_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            file_label.add_css_class ("dim-label");
            file_row.append (file_label);
            var choose = new Button.with_label (_("Choose Image"));
            choose.clicked.connect (choose_file);
            file_row.append (choose);
            body.append (file_row);
            read_only = new Switch ();
            read_only.active = true;
            row (_("Read-Only"), read_only);
            var hint = new Label (_("The image appears as a disk until it is detached or the computer restarts."));
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            body.append (hint);
            primary.sensitive = false;
        }

        private void choose_file () {
            var dialog = new FileDialog ();
            dialog.title = _("Choose Disk Image");
            dialog.open.begin (this, null, (obj, res) => {
                try {
                    var chosen = dialog.open.end (res);
                    if (chosen == null || chosen.get_path () == null) return;
                    file = chosen;
                    file_label.label = chosen.get_path ();
                    file_label.remove_css_class ("dim-label");
                    primary.sensitive = true;
                } catch (Error e) {
                }
            });
        }

        protected override string? validate () {
            return file == null ? _("Choose an image file.") : null;
        }

        protected override async void perform () throws Error {
            yield client.loop_setup (file.get_path (), read_only.active);
        }
    }
}
