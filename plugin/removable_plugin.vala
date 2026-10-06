using Gtk;
using Singularity;
using Singularity.Widgets;
using Singularity.Apps.Disks;

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Singularity.Plugin), typeof (SingularityDisksPlugin.RemovablePlugin));
}

namespace SingularityDisksPlugin {

    public void open_disks () {
        var info = new GLib.DesktopAppInfo ("dev.sinty.disks.desktop");
        if (info == null) return;
        try {
            info.launch (null, Gdk.Display.get_default ().get_app_launch_context ());
        } catch (Error e) {
            warning ("disks: %s", e.message);
        }
    }

    public void open_folder (string path) {
        try {
            AppInfo.launch_default_for_uri (File.new_for_path (path).get_uri (), Gdk.Display.get_default ().get_app_launch_context ());
        } catch (Error e) {
            warning ("disks: %s", e.message);
        }
    }

    public class RemovablePlugin : Object, Singularity.Plugin {
        private PluginContext context;
        private EjectIndicator? indicator;
        private RemovableWidgetProvider? provider;

        public void activate (PluginContext ctx) {
            context = ctx;
            indicator = new EjectIndicator ();
            context.add_panel_widget (indicator, Align.END);
            provider = new RemovableWidgetProvider ();
            context.add_overview_widget (provider);
        }

        public void deactivate () {
            if (indicator != null) {
                context.remove_panel_widget (indicator);
                indicator = null;
            }
            if (provider != null) {
                context.remove_overview_widget (provider);
                provider = null;
            }
        }

        public Gtk.Widget? get_settings_widget () {
            return null;
        }
    }

    public class EjectIndicator : Box {
        private MenuButton button;
        private PreferencesGroup group;
        private Gee.ArrayList<Widget> rows = new Gee.ArrayList<Widget> ();
        private RemovableMonitor monitor;

        public EjectIndicator () {
            Object (orientation: Orientation.HORIZONTAL, spacing: 0);
            valign = Align.CENTER;
            button = new MenuButton ();
            button.add_css_class ("flat");
            button.add_css_class ("panel-button");
            button.icon_name = "media-eject-symbolic";
            button.tooltip_text = _("Removable Media");
            append (button);

            var content = new Box (Orientation.VERTICAL, 6);
            content.margin_top = 6;
            content.margin_bottom = 6;
            content.margin_start = 6;
            content.margin_end = 6;
            content.width_request = 320;
            group = new PreferencesGroup (_("Removable Media"));
            content.append (group);
            var open = new Button.with_label (_("Open Disks"));
            open.halign = Align.END;
            open.clicked.connect (() => {
                button.popdown ();
                open_disks ();
            });
            content.append (open);
            var popover = new Popover ();
            popover.child = content;
            button.popover = popover;

            monitor = RemovableMonitor.get_default ();
            monitor.changed.connect (rebuild);
            rebuild ();
        }

        private void rebuild () {
            visible = monitor.any_mounted ();
            foreach (var r in rows) group.remove_row (r);
            rows.clear ();
            foreach (var m in monitor.media) {
                var row = new ActionRow (m.title, m.detail (), m.symbolic_icon);
                var eject = new CircularButton ("media-eject-symbolic", _("Eject"));
                eject.valign = Align.CENTER;
                eject.sensitive = !m.busy;
                eject.clicked.connect (() => monitor.eject.begin (m));
                row.add_suffix (eject);
                if (m.mounted) {
                    string point = m.mount_point;
                    row.activated.connect (() => {
                        button.popdown ();
                        open_folder (point);
                    });
                }
                group.add_row (row);
                rows.add (row);
            }
            if (monitor.media.size == 0) button.popdown ();
        }
    }
}
