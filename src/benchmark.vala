using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Disks {

    [CCode (cname = "pread", cheader_filename = "unistd.h")]
    private extern ssize_t pread (int fd, void* buf, size_t count, int64 offset);

    public class BenchmarkChart : DrawingArea {
        public string unit;
        public bool dots;
        private double[] xs = {};
        private double[] ys = {};
        public double fixed_max = 0;

        public BenchmarkChart (string unit, bool dots) {
            this.unit = unit;
            this.dots = dots;
            set_size_request (-1, 110);
            hexpand = true;
            add_css_class ("disks-chart");
            set_draw_func (draw);
        }

        public void add (double x, double y) {
            xs += x;
            ys += y;
            queue_draw ();
        }

        public void clear () {
            xs = {};
            ys = {};
            queue_draw ();
        }

        private void draw (DrawingArea area, Cairo.Context cr, int width, int height) {
            var fg = get_color ();
            double max = fixed_max;
            foreach (double y in ys) max = double.max (max, y);
            if (max <= 0) max = 1;
            double nice = Math.pow (10, Math.floor (Math.log10 (max)));
            foreach (double step in new double[] { 1, 2, 2.5, 5, 10 }) {
                if (nice * step >= max) {
                    max = nice * step;
                    break;
                }
            }
            var layout = create_pango_layout ("");
            int lw = 0, lh = 0;
            for (int i = 0; i <= 4; i += 2) {
                layout.set_markup ("<small>%s</small>".printf (Markup.escape_text ("%g %s".printf (max * (4 - i) / 4.0, unit))), -1);
                int w, h;
                layout.get_pixel_size (out w, out h);
                lw = int.max (lw, w);
                lh = int.max (lh, h);
            }
            double left = lw + 10, top = lh / 2.0 + 2, bottom = height - 4.0, right = width - 4.0;
            cr.set_line_width (1);
            for (int i = 0; i <= 4; i++) {
                double y = top + (bottom - top) * i / 4.0;
                cr.set_source_rgba (fg.red, fg.green, fg.blue, i == 4 ? 0.28 : 0.10);
                cr.move_to (left, Math.round (y) + 0.5);
                cr.line_to (right, Math.round (y) + 0.5);
                cr.stroke ();
                if (i % 2 == 0) {
                    layout.set_markup ("<small>%s</small>".printf (Markup.escape_text ("%g %s".printf (max * (4 - i) / 4.0, unit))), -1);
                    int w, h;
                    layout.get_pixel_size (out w, out h);
                    cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.6);
                    cr.move_to (left - 6 - w, y - h / 2.0);
                    Pango.cairo_show_layout (cr, layout);
                }
            }
            if (xs.length == 0) return;
            var accent = Gdk.RGBA ();
            accent.parse ("#3584e4");
            cr.set_source_rgba (accent.red, accent.green, accent.blue, 1);
            if (dots) {
                for (int i = 0; i < xs.length; i++) {
                    double x = left + (right - left) * xs[i];
                    double y = bottom - (bottom - top) * double.min (1, ys[i] / max);
                    cr.arc (x, y, 1.6, 0, 2 * Math.PI);
                    cr.fill ();
                }
                return;
            }
            cr.set_line_width (2);
            cr.set_line_join (Cairo.LineJoin.ROUND);
            for (int i = 0; i < xs.length; i++) {
                double x = left + (right - left) * xs[i];
                double y = bottom - (bottom - top) * double.min (1, ys[i] / max);
                if (i == 0) cr.move_to (x, y); else cr.line_to (x, y);
            }
            cr.stroke ();
        }
    }

    public class BenchmarkDialog : AppDialog {
        private const int SAMPLES = 100;
        private const int ACCESS_SAMPLES = 1000;
        private UObject block;
        private BenchmarkChart rate_chart;
        private BenchmarkChart access_chart;
        private Label avg_rate;
        private Label min_rate;
        private Label max_rate;
        private Label avg_access;
        private Label status;
        private SpinButton sample_mb;
        private Button start_button;
        private int stop = 0;
        private bool running = false;

        public BenchmarkDialog (DisksApp app, UObject block) {
            base (app, true);
            transient_for = dialog_parent (app, this);
            this.block = block;
            set_title (_("Benchmark"));
            set_default_size (620, -1);
            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_top = 8;
            box.margin_start = 20;
            box.margin_end = 20;
            box.margin_bottom = 16;
            var intro = new Label (_("Measures how fast %s reads data and how quickly it finds it. Nothing is written to the drive.").printf (block.device ()));
            intro.wrap = true;
            intro.xalign = 0;
            intro.add_css_class ("dim-label");
            box.append (intro);

            var stats = new Grid ();
            stats.column_spacing = 24;
            stats.row_spacing = 2;
            stats.column_homogeneous = true;
            avg_rate = stat (stats, 0, _("Average Read Rate"));
            min_rate = stat (stats, 1, _("Slowest"));
            max_rate = stat (stats, 2, _("Fastest"));
            avg_access = stat (stats, 3, _("Access Time"));
            box.append (stats);

            var rate_title = new Label (_("Read Rate Across the Drive"));
            rate_title.xalign = 0;
            rate_title.add_css_class ("heading");
            box.append (rate_title);
            rate_chart = new BenchmarkChart ("MB/s", false);
            box.append (rate_chart);
            var access_title = new Label (_("Access Time"));
            access_title.xalign = 0;
            access_title.add_css_class ("heading");
            box.append (access_title);
            access_chart = new BenchmarkChart ("ms", true);
            box.append (access_chart);

            var actions = new Box (Orientation.HORIZONTAL, 8);
            actions.margin_top = 8;
            actions.append (new Label (_("Sample Size")));
            sample_mb = new SpinButton.with_range (1, 1000, 1);
            sample_mb.value = 10;
            actions.append (sample_mb);
            actions.append (new Label ("MB"));
            status = new Label ("");
            status.hexpand = true;
            status.xalign = 1;
            status.wrap = true;
            status.add_css_class ("dim-label");
            actions.append (status);
            start_button = new Button.with_label (_("Start"));
            start_button.add_css_class ("suggested-action");
            start_button.clicked.connect (() => {
                if (running) AtomicInt.set (ref stop, 1);
                else run.begin ();
            });
            actions.append (start_button);
            box.append (actions);
            content_box.append (box);
            close_request.connect (() => {
                AtomicInt.set (ref stop, 1);
                return false;
            });
        }

        private Label stat (Grid grid, int col, string title) {
            var t = new Label (title);
            t.xalign = 0;
            t.add_css_class ("dim-label");
            t.add_css_class ("caption");
            var v = new Label ("-");
            v.xalign = 0;
            v.add_css_class ("title-4");
            grid.attach (t, col, 0, 1, 1);
            grid.attach (v, col, 1, 1, 1);
            return v;
        }

        private async void run () {
            int fd;
            status.label = _("Opening the drive");
            try {
                UnixFDList? fds;
                var reply = yield block.call_with_fd (IFACE_BLOCK, "OpenDevice", new Variant ("(s@a{sv})", "r", empty_options ()), out fds);
                int32 index;
                reply.get ("(h)", out index);
                fd = fds.get (index);
            } catch (Error e) {
                status.label = DisksWindow.describe_error (e);
                return;
            }
            running = true;
            AtomicInt.set (ref stop, 0);
            start_button.label = _("Stop");
            start_button.remove_css_class ("suggested-action");
            sample_mb.sensitive = false;
            rate_chart.clear ();
            access_chart.clear ();
            foreach (var l in new Label[] { avg_rate, min_rate, max_rate, avg_access }) l.label = "-";
            uint64 size = block.u64 (IFACE_BLOCK, "Size");
            uint64 sample = (uint64) sample_mb.value * 1000 * 1000;
            sample = uint64.min (sample, size / SAMPLES) & ~((uint64) 4095);
            if (sample < 4096) sample = 4096;
            double sum = 0, lo = double.MAX, hi = 0;
            int count = 0;
            double access_sum = 0;
            int access_count = 0;
            string? failure = null;
            SourceFunc callback = run.callback;
            new Thread<void*> ("disks-benchmark", () => {
                var buffer = new uint8[sample];
                for (int i = 0; i < SAMPLES && AtomicInt.get (ref stop) == 0; i++) {
                    uint64 offset = size > sample ? ((size - sample) / (SAMPLES - 1) * i) & ~((uint64) 4095) : 0;
                    fadvise (fd, (int64) offset, (int64) sample, 4);
                    int64 t0 = get_monotonic_time ();
                    ssize_t n = pread (fd, buffer, (size_t) sample, (int64) offset);
                    int64 t1 = get_monotonic_time ();
                    if (n <= 0) {
                        failure = _("Reading failed: %s").printf (strerror (errno));
                        break;
                    }
                    double rate = n / ((t1 - t0) / 1000000.0) / 1000000.0;
                    double x = size > 0 ? (double) offset / size : 0;
                    Idle.add (() => {
                        rate_chart.add (x, rate);
                        sum += rate;
                        count++;
                        lo = double.min (lo, rate);
                        hi = double.max (hi, rate);
                        avg_rate.label = Format.rate (sum / count * 1000000);
                        min_rate.label = Format.rate (lo * 1000000);
                        max_rate.label = Format.rate (hi * 1000000);
                        status.label = _("Measuring read rate");
                        return Source.REMOVE;
                    });
                }
                var small = new uint8[4096];
                for (int i = 0; i < ACCESS_SAMPLES && failure == null && AtomicInt.get (ref stop) == 0; i++) {
                    uint64 offset = size > 4096 ? ((uint64) Random.next_int () << 32 | Random.next_int ()) % (size - 4096) & ~((uint64) 4095) : 0;
                    fadvise (fd, (int64) offset, 4096, 4);
                    int64 t0 = get_monotonic_time ();
                    ssize_t n = pread (fd, small, 4096, (int64) offset);
                    int64 t1 = get_monotonic_time ();
                    if (n <= 0) {
                        failure = _("Reading failed: %s").printf (strerror (errno));
                        break;
                    }
                    double ms = (t1 - t0) / 1000.0;
                    double x = size > 0 ? (double) offset / size : 0;
                    Idle.add (() => {
                        access_chart.add (x, ms);
                        access_sum += ms;
                        access_count++;
                        avg_access.label = "%.2f ms".printf (access_sum / access_count);
                        status.label = _("Measuring access time");
                        return Source.REMOVE;
                    });
                }
                Posix.close (fd);
                Idle.add ((owned) callback);
                return null;
            });
            yield;
            running = false;
            start_button.label = _("Start");
            start_button.add_css_class ("suggested-action");
            sample_mb.sensitive = true;
            if (failure != null) status.label = failure;
            else if (AtomicInt.get (ref stop) != 0) status.label = _("Stopped");
            else status.label = _("Finished");
        }
    }
}
