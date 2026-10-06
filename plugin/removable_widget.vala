using Gtk;
using Singularity;
using Singularity.Widgets;
using Singularity.Apps.Disks;

namespace SingularityDisksPlugin {

    public class RemovableWidgetProvider : Object, OverviewWidgetProvider {
        private WidgetSize[] sizes = { WidgetSize (2, 1), WidgetSize (2, 2) };

        public string id { get { return "disks.removable"; } }
        public string provider_id { get { return "dev.sinty.disks"; } }
        public string display_name { get { return _("Removable Media"); } }
        public string icon_name { get { return "drive-removable-media-symbolic"; } }
        public WidgetSize[] supported_sizes { get { return sizes; } }

        public Gtk.Widget create_instance (string instance_id, WidgetSize size, Variant? config) {
            return new RemovableInstance (size);
        }
    }

    public class RemovableInstance : Box {
        private Box list;
        private Box empty;
        private Label more;
        private int limit;
        private RemovableMonitor monitor;
        private ulong handler;

        public RemovableInstance (WidgetSize size) {
            Object (orientation: Orientation.VERTICAL, spacing: 8);
            add_css_class ("overview-removable");
            install_css ();
            hexpand = true;
            vexpand = true;
            limit = size.h >= 2 ? 3 : 1;

            var title = new Label (_("Removable Media"));
            title.add_css_class ("caption-heading");
            title.opacity = 0.7;
            title.halign = Align.START;
            append (title);

            list = new Box (Orientation.VERTICAL, 6);
            list.vexpand = true;
            append (list);

            empty = new Box (Orientation.VERTICAL, 6);
            empty.valign = Align.CENTER;
            empty.vexpand = true;
            var icon = new Image.from_icon_name ("drive-removable-media");
            icon.pixel_size = size.h >= 2 ? 48 : 32;
            icon.opacity = 0.5;
            empty.append (icon);
            var none = new Label (_("No removable media"));
            none.add_css_class ("dim-label");
            empty.append (none);
            append (empty);

            more = new Label ("");
            more.add_css_class ("caption");
            more.add_css_class ("dim-label");
            more.halign = Align.START;
            append (more);

            monitor = RemovableMonitor.get_default ();
            handler = monitor.changed.connect (rebuild);
            destroy.connect (() => {
                if (handler != 0) monitor.disconnect (handler);
                handler = 0;
            });
            rebuild ();
        }

        private static bool css_installed;

        private static void install_css () {
            if (css_installed) return;
            css_installed = true;
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private const string CSS = """
.overview-removable {
    padding: 12px 14px;
    border-radius: 20px;
    background: alpha(@window_bg_color, 0.30);
    border: 1px solid alpha(@window_fg_color, 0.08);
}

.overview-removable-card {
    padding: 8px 10px;
    border-radius: 12px;
    background: alpha(@window_fg_color, 0.04);
}
""";

        private void rebuild () {
            for (var c = list.get_first_child (); c != null; c = list.get_first_child ()) list.remove (c);
            int shown = 0;
            foreach (var m in monitor.media) {
                if (shown >= limit) break;
                list.append (build_row (m));
                shown++;
            }
            int hidden = monitor.media.size - shown;
            more.label = hidden > 0 ? ngettext ("%d more", "%d more", hidden).printf (hidden) : "";
            more.visible = hidden > 0;
            empty.visible = monitor.media.size == 0;
            list.visible = monitor.media.size > 0;
        }

        private Widget build_row (Medium m) {
            var row = new Box (Orientation.HORIZONTAL, 10);
            row.add_css_class ("overview-removable-card");
            var icon = new Image.from_icon_name (m.icon_name);
            icon.pixel_size = 32;
            icon.valign = Align.CENTER;
            row.append (icon);

            var labels = new Box (Orientation.VERTICAL, 3);
            labels.hexpand = true;
            labels.valign = Align.CENTER;
            var name = new Label (m.title);
            name.add_css_class ("heading");
            name.halign = Align.START;
            name.ellipsize = Pango.EllipsizeMode.END;
            labels.append (name);
            var detail = new Label (m.detail ());
            detail.add_css_class ("caption");
            detail.add_css_class ("dim-label");
            detail.halign = Align.START;
            detail.ellipsize = Pango.EllipsizeMode.END;
            labels.append (detail);
            if (m.has_usage) {
                var bar = new LevelBar.for_interval (0, 1);
                bar.value = m.used_fraction ();
                bar.add_offset_value (LEVEL_BAR_OFFSET_LOW, 0.8);
                bar.add_offset_value (LEVEL_BAR_OFFSET_HIGH, 0.9);
                bar.add_offset_value (LEVEL_BAR_OFFSET_FULL, 1.0);
                labels.append (bar);
            }
            row.append (labels);

            var eject = new CircularButton ("media-eject-symbolic", _("Eject"));
            eject.valign = Align.CENTER;
            eject.sensitive = !m.busy;
            eject.clicked.connect (() => monitor.eject.begin (m));
            row.append (eject);

            if (m.mounted) {
                string point = m.mount_point;
                var click = new GestureClick ();
                click.released.connect ((n, x, y) => {
                    var target = row.pick (x, y, PickFlags.DEFAULT);
                    for (var w = target; w != null && w != row; w = w.get_parent ()) {
                        if (w is Button) return;
                    }
                    open_folder (point);
                });
                row.add_controller (click);
                row.cursor = new Gdk.Cursor.from_name ("pointer", null);
            }
            return row;
        }
    }
}
