using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Disks {

    public class DisksApp : Singularity.Application {

        private bool attach_pending;

        public DisksApp () {
            Object (application_id: "dev.sinty.disks", flags: ApplicationFlags.DEFAULT_FLAGS);
            add_main_option ("attach-image", 0, OptionFlags.NONE, OptionArg.NONE, _("Attach a disk image"), null);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("attach-image")) return -1;
            try {
                register (null);
            } catch (Error e) {
                warning ("disks: %s", e.message);
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("attach-image", null);
                return 0;
            }
            attach_pending = true;
            return -1;
        }

        protected override void startup () {
            base.startup ();
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);

            var menu = new GLib.Menu ();
            var file_menu = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("Attach Disk Image…"), "app.attach-image");
            file_menu.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Close Window"), "win.close");
            f2.append (_("Quit"), "app.quit");
            file_menu.append_section (null, f2);
            menu.append_submenu (_("File"), file_menu);
            var edit_menu = new GLib.Menu ();
            edit_menu.append (_("Settings"), "app.settings");
            menu.append_submenu (_("Edit"), edit_menu);
            var view_menu = new GLib.Menu ();
            view_menu.append (_("Toggle Sidebar"), "win.toggle-sidebar");
            menu.append_submenu (_("View"), view_menu);
            var disk_menu = new GLib.Menu ();
            var d1 = new GLib.Menu ();
            d1.append (_("Format Disk…"), "win.format-disk");
            disk_menu.append_section (null, d1);
            var d2 = new GLib.Menu ();
            d2.append (_("Create Disk Image…"), "win.create-disk-image");
            d2.append (_("Restore Disk Image…"), "win.restore-disk-image");
            d2.append (_("Benchmark Disk…"), "win.benchmark-disk");
            disk_menu.append_section (null, d2);
            var d3 = new GLib.Menu ();
            d3.append (_("Drive Health…"), "win.drive-health");
            d3.append (_("Drive Settings…"), "win.drive-settings");
            d3.append (_("Standby Now"), "win.standby");
            d3.append (_("Wake Up"), "win.wake-up");
            disk_menu.append_section (null, d3);
            var d4 = new GLib.Menu ();
            d4.append (_("Eject"), "win.eject");
            d4.append (_("Safely Remove"), "win.safely-remove");
            d4.append (_("Detach Image"), "win.detach-image");
            disk_menu.append_section (null, d4);
            menu.append_submenu (_("Disk"), disk_menu);
            var volume_menu = new GLib.Menu ();
            var v1 = new GLib.Menu ();
            v1.append (_("Mount"), "win.mount");
            v1.append (_("Unmount"), "win.unmount");
            v1.append (_("Unlock…"), "win.unlock");
            v1.append (_("Lock"), "win.lock");
            volume_menu.append_section (null, v1);
            var v2 = new GLib.Menu ();
            v2.append (_("Create Partition…"), "win.create-partition");
            v2.append (_("Format Volume…"), "win.format-volume");
            v2.append (_("Edit Partition…"), "win.edit-partition");
            v2.append (_("Resize…"), "win.resize");
            v2.append (_("Delete Partition…"), "win.delete-partition");
            volume_menu.append_section (null, v2);
            var v3 = new GLib.Menu ();
            v3.append (_("Rename…"), "win.rename");
            v3.append (_("Mount Options…"), "win.mount-options");
            v3.append (_("Change Passphrase…"), "win.change-passphrase");
            v3.append (_("Check Filesystem"), "win.check-filesystem");
            v3.append (_("Repair Filesystem…"), "win.repair-filesystem");
            volume_menu.append_section (null, v3);
            var v4 = new GLib.Menu ();
            v4.append (_("Create Image of Volume…"), "win.create-volume-image");
            v4.append (_("Restore Image to Volume…"), "win.restore-volume-image");
            v4.append (_("Benchmark Volume…"), "win.benchmark-volume");
            volume_menu.append_section (null, v4);
            menu.append_submenu (_("Volume"), volume_menu);
            set_menubar (menu);

            var attach = new SimpleAction ("attach-image", null);
            attach.activate.connect (() => {
                if (get_active_window () == null) {
                    attach_pending = true;
                    activate ();
                    return;
                }
                show_attach ();
            });
            add_action (attach);
            var quit_action = new SimpleAction ("quit", null);
            quit_action.activate.connect (() => {
                foreach (var w in get_windows ()) w.close ();
            });
            add_action (quit_action);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.disks");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (settings_action);
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.toggle-sidebar", { "F9" });
            set_accels_for_action ("app.attach-image", { "<Control>o" });
            set_accels_for_action ("app.quit", { "<Control>q" });
        }

        public override void activate () {
            var window = get_active_window ();
            if (window == null) window = new DisksWindow (this);
            window.present ();
            if (attach_pending) {
                attach_pending = false;
                int tries = 0;
                Timeout.add (200, () => {
                    var w = get_active_window () as DisksWindow;
                    if (w != null && w.disks_client () != null) {
                        show_attach ();
                        return Source.REMOVE;
                    }
                    return ++tries < 50 ? Source.CONTINUE : Source.REMOVE;
                });
            }
        }

        private void show_attach () {
            var window = get_active_window () as DisksWindow;
            if (window == null || window.disks_client () == null) return;
            var dialog = new AttachImageDialog (this, window.disks_client ());
            dialog.transient_for = window;
            dialog.present ();
        }

        private const string CSS = """
.disks-info > label.dim-label {
    font-weight: 500;
}

.disks-volume-bar {
    min-height: 96px;
}

.disks-volume-bar:focus-visible {
    outline: 2px solid alpha(@accent_bg_color, 0.6);
    outline-offset: 2px;
    border-radius: 10px;
}

.disks-fs-list checkbutton {
    padding: 6px 4px;
}

.disks-job {
    padding: 10px 12px;
    border-radius: 12px;
    background-color: alpha(@accent_bg_color, 0.10);
}

.disks-attributes label {
    font-feature-settings: "tnum";
}

.disks-chart {
    padding: 4px 0;
}
""";
    }
}
