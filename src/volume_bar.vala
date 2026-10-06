using Gtk;

namespace Singularity.Apps.Disks {

    public class VolumeBar : DrawingArea {
        private Gee.List<Segment> segments = new Gee.ArrayList<Segment> ();
        private UDisksClient client;
        private double[] xs = {};
        private double[] ws = {};
        private bool[] lower = {};
        public int selected { get; private set; default = -1; }
        public bool inner_selected { get; private set; default = false; }

        public signal void activated (Segment segment, UObject? inner);

        public VolumeBar (UDisksClient client) {
            this.client = client;
            add_css_class ("disks-volume-bar");
            set_size_request (-1, 96);
            hexpand = true;
            set_draw_func (draw);
            var click = new GestureClick ();
            click.pressed.connect ((n, x, y) => pick_at (x, y));
            add_controller (click);
            focusable = true;
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                if (segments.size == 0) return false;
                if (keyval == Gdk.Key.Right) {
                    select (int.min (segments.size - 1, selected + 1), false);
                    return true;
                }
                if (keyval == Gdk.Key.Left) {
                    select (int.max (0, selected - 1), false);
                    return true;
                }
                return false;
            });
            add_controller (keys);
        }

        public void set_segments (Gee.List<Segment> list, string? keep_path) {
            segments = list;
            int index = 0;
            bool inner = false;
            if (keep_path != null) {
                for (int i = 0; i < list.size; i++) {
                    var b = list[i].block;
                    if (b == null) continue;
                    if (b.path == keep_path) index = i;
                    if (b.has (IFACE_ENCRYPTED)) {
                        var clear = client.cleartext (b);
                        if (clear != null && clear.path == keep_path) {
                            index = i;
                            inner = true;
                        }
                    }
                }
            }
            queue_draw ();
            select (index, inner);
        }

        public void select (int index, bool inner) {
            if (index < 0 || index >= segments.size) return;
            selected = index;
            var seg = segments[index];
            UObject? clear = seg.block != null && seg.block.has (IFACE_ENCRYPTED) ? client.cleartext (seg.block) : null;
            inner_selected = inner && clear != null;
            queue_draw ();
            activated (seg, inner_selected ? clear : null);
        }

        private void pick_at (double x, double y) {
            grab_focus ();
            if (y >= get_height () / 2.0) {
                for (int i = 0; i < xs.length; i++) {
                    if (lower[i] && x >= xs[i] && x <= xs[i] + ws[i]) {
                        select (i, false);
                        return;
                    }
                }
            }
            for (int i = 0; i < xs.length; i++) {
                if (x < xs[i] || x > xs[i] + ws[i]) continue;
                if (lower[i]) continue;
                var seg = segments[i];
                bool inner = seg.block != null && seg.block.has (IFACE_ENCRYPTED) && y > get_height () / 2.0;
                select (i, inner);
                return;
            }
            for (int i = 0; i < xs.length; i++) {
                if (x >= xs[i] && x <= xs[i] + ws[i] && !segments[i].logical) {
                    select (i, false);
                    return;
                }
            }
        }

        private string label_for (Segment seg) {
            if (seg.free) return _("Free Space");
            var b = seg.block;
            if (seg.extended) return _("Extended Partition");
            string label = b.str (IFACE_BLOCK, "IdLabel");
            if (label == "") label = b.str (IFACE_PARTITION, "Name");
            if (label == "") label = Format.filesystem_name (b.str (IFACE_BLOCK, "IdType"), b.str (IFACE_BLOCK, "IdVersion"));
            return label;
        }

        private void round_rect (Cairo.Context cr, double x, double y, double w, double h, double r) {
            r = double.min (r, double.min (w, h) / 2);
            cr.new_sub_path ();
            cr.arc (x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc (x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc (x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc (x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path ();
        }

        private void color_for (Segment seg, UObject? inner, out double r, out double g, out double b) {
            if (seg.free) { r = 0.55; g = 0.57; b = 0.6; return; }
            var block = inner ?? seg.block;
            string type = block.str (IFACE_BLOCK, "IdType");
            if (seg.extended) { r = 0.45; g = 0.47; b = 0.52; return; }
            if (type == "crypto_LUKS") { r = 0.75; g = 0.45; b = 0.15; return; }
            if (type == "swap") { r = 0.55; g = 0.35; b = 0.75; return; }
            if (type == "vfat" || type == "exfat" || type == "ntfs") { r = 0.18; g = 0.6; b = 0.45; return; }
            if (type == "") { r = 0.5; g = 0.5; b = 0.55; return; }
            r = 0.21; g = 0.52; b = 0.89;
        }

        private void draw (DrawingArea area, Cairo.Context cr, int width, int height) {
            int n = segments.size;
            xs = new double[n];
            ws = new double[n];
            lower = new bool[n];
            if (n == 0) return;
            uint64 total = 0;
            uint64 base_offset = segments[0].offset;
            uint64 end = 0;
            foreach (var s in segments) {
                if (s.logical) continue;
                end = uint64.max (end, s.offset + s.size);
            }
            total = end - base_offset;
            if (total == 0) total = 1;
            double min_w = 30;
            double avail = width - 2;
            int top_count = 0;
            foreach (var s in segments) if (!s.logical) top_count++;
            double flexible = avail - min_w * top_count;
            if (flexible < 0) flexible = 0;
            double x = 1;
            var fg = get_color ();
            Pango.Layout layout = create_pango_layout ("");
            for (int i = 0; i < n; i++) {
                var seg = segments[i];
                if (seg.logical) continue;
                double w = min_w + flexible * ((double) seg.size / total);
                xs[i] = x;
                ws[i] = w;
                x += w;
            }
            for (int i = 0; i < n; i++) {
                var seg = segments[i];
                if (!seg.logical) continue;
                int parent = -1;
                for (int j = i; j >= 0; j--) if (segments[j].extended) { parent = j; break; }
                if (parent < 0) continue;
                var ext = segments[parent];
                double frac_start = (double) (seg.offset - ext.offset) / double.max (1, ext.size);
                double frac_size = (double) seg.size / double.max (1, ext.size);
                xs[i] = xs[parent] + 4 + (ws[parent] - 8) * frac_start;
                ws[i] = double.max (14, (ws[parent] - 8) * frac_size);
                lower[i] = true;
            }
            for (int i = 0; i < n; i++) {
                var seg = segments[i];
                double sx = xs[i] + 1, sw = ws[i] - 2;
                double sy = seg.logical ? height / 2.0 + 2 : 1;
                double sh = seg.logical ? height / 2.0 - 5 : height - 2;
                UObject? clear = seg.block != null && seg.block.has (IFACE_ENCRYPTED) ? client.cleartext (seg.block) : null;
                double r, g, b;
                color_for (seg, null, out r, out g, out b);
                round_rect (cr, sx, sy, sw, sh, 8);
                if (seg.free) {
                    cr.set_source_rgba (r, g, b, 0.18);
                    cr.fill_preserve ();
                    cr.set_source_rgba (r, g, b, 0.6);
                    cr.set_line_width (1.2);
                    cr.set_dash ({ 4, 3 }, 0);
                    cr.stroke ();
                    cr.set_dash (null, 0);
                } else if (seg.extended) {
                    cr.set_source_rgba (r, g, b, 0.22);
                    cr.fill_preserve ();
                    cr.set_source_rgba (r, g, b, 0.8);
                    cr.set_line_width (1.2);
                    cr.stroke ();
                } else {
                    cr.set_source_rgba (r, g, b, 0.85);
                    cr.fill ();
                    if (clear != null) {
                        double cr_, cg, cb;
                        color_for (seg, clear, out cr_, out cg, out cb);
                        round_rect (cr, sx + 3, sy + sh / 2, sw - 6, sh / 2 - 3, 6);
                        cr.set_source_rgba (cr_, cg, cb, 0.95);
                        cr.fill ();
                    }
                }
                bool is_sel = i == selected;
                if (is_sel) {
                    double hy = sy, hh = sh;
                    if (clear != null && inner_selected) { hy = sy + sh / 2; hh = sh / 2; }
                    else if (clear != null) { hh = sh / 2; }
                    round_rect (cr, sx - 0.5, hy - 0.5, sw + 1, hh + 1, 8);
                    cr.set_source_rgba (1, 1, 1, 0.95);
                    cr.set_line_width (3);
                    cr.stroke ();
                    round_rect (cr, sx - 0.5, hy - 0.5, sw + 1, hh + 1, 8);
                    cr.set_source_rgba (0.21, 0.52, 0.89, 1);
                    cr.set_line_width (1.5);
                    cr.stroke ();
                }
                if (sw < 48) continue;
                string title = label_for (seg);
                string sub = Format.size (seg.size);
                if (seg.block != null && seg.block.has (IFACE_ENCRYPTED)) sub = (clear != null ? _("Unlocked") : _("Locked")) + ", " + sub;
                if (seg.block != null && seg.block.has (IFACE_FILESYSTEM) && seg.block.mount_points ().length > 0) sub += ", " + _("mounted");
                layout.set_markup ("<b>%s</b>\n<small>%s</small>".printf (Markup.escape_text (title), Markup.escape_text (sub)), -1);
                layout.set_width ((int) ((sw - 12) * Pango.SCALE));
                layout.set_ellipsize (Pango.EllipsizeMode.END);
                layout.set_height (-2);
                int lw, lh;
                layout.get_pixel_size (out lw, out lh);
                double ty = seg.logical ? sy + (sh - lh) / 2 : (clear != null ? sy + (sh / 2 - lh) / 2 : sy + (sh - lh) / 2);
                if (seg.extended) ty = sy + 6;
                cr.move_to (sx + 6, ty);
                if (seg.free || seg.extended) cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.85);
                else cr.set_source_rgba (1, 1, 1, 1);
                Pango.cairo_show_layout (cr, layout);
                if (clear != null && sh > 40) {
                    string inner_title = clear.str (IFACE_BLOCK, "IdLabel");
                    if (inner_title == "") inner_title = Format.filesystem_name (clear.str (IFACE_BLOCK, "IdType"), clear.str (IFACE_BLOCK, "IdVersion"));
                    layout.set_markup ("<small>%s</small>".printf (Markup.escape_text (inner_title)), -1);
                    layout.get_pixel_size (out lw, out lh);
                    cr.move_to (sx + 9, sy + sh / 2 + (sh / 2 - 3 - lh) / 2);
                    cr.set_source_rgba (1, 1, 1, 1);
                    Pango.cairo_show_layout (cr, layout);
                }
            }
        }
    }
}
