using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Disks {

    public class SmartDialog : AppDialog {
        private UObject drive;
        private bool nvme;
        private Label assessment;
        private Label assessment_detail;
        private Grid summary;
        private Grid attributes;
        private Label test_status;
        private ProgressBar test_progress;
        private Button test_button;
        private Button abort_button;
        private Button refresh_button;
        private Switch enabled_switch;
        private Label error_label;
        private ulong changed_handler;
        private UDisksClient client;

        public SmartDialog (DisksApp app, UDisksClient client, UObject drive) {
            base (app, true);
            transient_for = dialog_parent (app, this);
            this.drive = drive;
            this.client = client;
            nvme = drive.has (IFACE_NVME);
            set_title (_("Drive Health"));
            set_default_size (740, 560);

            var box = new Box (Orientation.VERTICAL, 14);
            box.margin_top = 8;
            box.margin_bottom = 16;
            box.margin_start = 20;
            box.margin_end = 20;

            var head = new Box (Orientation.HORIZONTAL, 14);
            var texts = new Box (Orientation.VERTICAL, 2);
            texts.hexpand = true;
            assessment = new Label ("");
            assessment.xalign = 0;
            assessment.add_css_class ("title-3");
            assessment_detail = new Label ("");
            assessment_detail.xalign = 0;
            assessment_detail.wrap = true;
            assessment_detail.add_css_class ("dim-label");
            texts.append (assessment);
            texts.append (assessment_detail);
            head.append (texts);
            if (!nvme) {
                var toggle = new Box (Orientation.HORIZONTAL, 8);
                toggle.valign = Align.CENTER;
                toggle.append (new Label (_("Monitoring")));
                enabled_switch = new Switch ();
                enabled_switch.active = drive.flag (IFACE_ATA, "SmartEnabled");
                enabled_switch.notify["active"].connect (() => set_enabled.begin (enabled_switch.active));
                toggle.append (enabled_switch);
                head.append (toggle);
            }
            box.append (head);

            summary = new Grid ();
            summary.add_css_class ("disks-info");
            summary.column_spacing = 16;
            summary.row_spacing = 6;
            box.append (summary);

            var test_box = new Box (Orientation.HORIZONTAL, 8);
            test_status = new Label ("");
            test_status.xalign = 0;
            test_status.hexpand = true;
            test_status.wrap = true;
            test_box.append (test_status);
            refresh_button = new Button.from_icon_name ("view-refresh-symbolic");
            refresh_button.tooltip_text = _("Read Health Data Again");
            refresh_button.clicked.connect (() => refresh.begin ());
            test_box.append (refresh_button);
            abort_button = new Button.with_label (_("Stop Test"));
            abort_button.clicked.connect (() => abort_test.begin ());
            test_box.append (abort_button);
            test_button = new Button.with_label (_("Run Self-Test"));
            test_button.add_css_class ("suggested-action");
            test_button.clicked.connect (show_test_menu);
            test_box.append (test_button);
            box.append (test_box);
            test_progress = new ProgressBar ();
            box.append (test_progress);

            error_label = new Label ("");
            error_label.add_css_class ("error");
            error_label.xalign = 0;
            error_label.wrap = true;
            error_label.visible = false;
            box.append (error_label);

            var section = new Label (nvme ? _("Health Log") : _("Attributes"));
            section.xalign = 0;
            section.add_css_class ("heading");
            box.append (section);
            attributes = new Grid ();
            attributes.column_spacing = 16;
            attributes.row_spacing = 4;
            attributes.add_css_class ("disks-attributes");
            var scroll = new ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.AUTOMATIC;
            scroll.child = attributes;
            scroll.set_size_request (-1, 160);
            box.append (scroll);

            content_box.append (box);
            changed_handler = client.changed.connect (sync);
            close_request.connect (() => {
                client.disconnect (changed_handler);
                return false;
            });
            sync ();
            bool enabled = nvme || drive.flag (IFACE_ATA, "SmartEnabled");
            if (enabled && drive.u64 (iface (), "SmartUpdated") == 0) refresh.begin ();
            else load_attributes.begin ();
        }

        private string iface () {
            return nvme ? IFACE_NVME : IFACE_ATA;
        }

        private void show_error (Error e) {
            error_label.label = DisksWindow.describe_error (e);
            error_label.visible = true;
        }

        private void add_summary (int row, string key, string value) {
            var k = new Label (key);
            k.xalign = 1;
            k.add_css_class ("dim-label");
            var v = new Label (value);
            v.xalign = 0;
            v.selectable = true;
            v.wrap = true;
            v.hexpand = true;
            summary.attach (k, 0, row, 1, 1);
            summary.attach (v, 1, row, 1, 1);
        }

        private void sync () {
            Widget? child;
            while ((child = summary.get_first_child ()) != null) summary.remove (child);
            string i = iface ();
            uint64 updated = drive.u64 (i, "SmartUpdated");
            double temp = nvme ? (double) drive.u64 (i, "SmartTemperature") : drive.dbl (i, "SmartTemperature");
            string status = drive.str (i, "SmartSelftestStatus");
            int row = 0;
            if (nvme) {
                var warnings = drive.prop (i, "SmartCriticalWarning");
                string[] list = warnings != null ? warnings.get_strv () : new string[0];
                if (list.length == 0) {
                    assessment.label = _("The drive is healthy");
                    assessment_detail.label = _("No critical warnings reported by the controller.");
                } else {
                    assessment.label = _("The drive reports a problem");
                    assessment_detail.label = string.joinv (", ", nvme_warnings (list));
                }
                uint64 hours = drive.u64 (i, "SmartPowerOnHours");
                if (hours > 0) add_summary (row++, _("Powered On"), Format.duration ((int64) hours * 3600));
            } else {
                bool supported = drive.flag (i, "SmartSupported");
                bool failing = drive.flag (i, "SmartFailing");
                int64 bad = drive.i64 (i, "SmartNumBadSectors");
                int64 failing_attrs = drive.i64 (i, "SmartNumAttributesFailing");
                if (supported && drive.flag (i, "SmartEnabled") && updated == 0) {
                    assessment.label = _("Reading health data");
                    assessment_detail.label = _("This takes a moment.");
                } else if (!supported) {
                    assessment.label = _("Health data not available");
                    assessment_detail.label = _("This drive does not support self-monitoring.");
                } else if (!drive.flag (i, "SmartEnabled")) {
                    assessment.label = _("Monitoring is turned off");
                    assessment_detail.label = _("Turn on monitoring to read the health of this drive.");
                } else if (failing) {
                    assessment.label = _("The drive is likely to fail soon");
                    assessment_detail.label = _("Copy your data to another drive and replace this one.");
                } else if (failing_attrs > 0) {
                    assessment.label = _("The drive shows signs of wear");
                    assessment_detail.label = ngettext ("%lld attribute is below its safe limit.", "%lld attributes are below their safe limit.", (ulong) failing_attrs).printf (failing_attrs);
                } else if (bad > 0) {
                    assessment.label = _("The drive is healthy, with bad sectors");
                    assessment_detail.label = ngettext ("%lld bad sector was found and replaced.", "%lld bad sectors were found and replaced.", (ulong) bad).printf (bad);
                } else {
                    assessment.label = _("The drive is healthy");
                    assessment_detail.label = _("All attributes are within their safe limits.");
                }
                uint64 seconds = drive.u64 (i, "SmartPowerOnSeconds");
                if (seconds > 0) add_summary (row++, _("Powered On"), Format.duration ((int64) seconds));
                if (bad >= 0 && supported) add_summary (row++, _("Bad Sectors"), bad.to_string ());
                if (enabled_switch != null && enabled_switch.active != drive.flag (i, "SmartEnabled")) {
                    enabled_switch.active = drive.flag (i, "SmartEnabled");
                }
            }
            if (temp > 0) add_summary (row++, _("Temperature"), Format.temperature (temp));
            if (updated > 0) {
                var when = new DateTime.from_unix_local ((int64) updated);
                add_summary (row++, _("Last Read"), when.format ("%-d %b %Y, %H:%M"));
            }
            int remaining = (int) drive.i64 (i, "SmartSelftestPercentRemaining");
            bool running = status == "inprogress";
            test_status.label = _("Self-Test: %s").printf (test_label (status));
            test_progress.visible = running;
            if (running && remaining >= 0) test_progress.fraction = (100 - remaining) / 100.0;
            abort_button.visible = running;
            test_button.sensitive = !running && (nvme || drive.flag (i, "SmartEnabled"));
            refresh_button.sensitive = nvme || drive.flag (i, "SmartEnabled");
        }

        private string[] nvme_warnings (string[] list) {
            string[] out_list = {};
            foreach (string w in list) {
                switch (w) {
                    case "spare": out_list += _("spare capacity is low"); break;
                    case "temperature": out_list += _("temperature is out of range"); break;
                    case "degraded": out_list += _("reliability is degraded"); break;
                    case "readonly": out_list += _("the drive became read-only"); break;
                    case "volatile_mem": out_list += _("the backup memory failed"); break;
                    case "pmr_readonly": out_list += _("persistent memory is read-only"); break;
                    default: out_list += w; break;
                }
            }
            return out_list;
        }

        private string test_label (string status) {
            switch (status) {
                case "success": return _("Last test passed");
                case "aborted": return _("Last test was stopped");
                case "interrupted": return _("Last test was interrupted");
                case "fatal": return _("Last test did not complete");
                case "error_unknown": case "error": return _("Last test failed");
                case "error_electrical": return _("Last test failed (electrical)");
                case "error_servo": return _("Last test failed (servo)");
                case "error_read": return _("Last test failed (read)");
                case "error_handling": return _("Last test failed (damage)");
                case "inprogress": return _("Running");
                case "": return _("Never run");
                default: return status;
            }
        }

        private void show_test_menu () {
            var menu = new ContextMenu (test_button);
            menu.add_item (_("Short Test (a few minutes)"), null, () => start_test.begin ("short"));
            menu.add_item (_("Extended Test (may take hours)"), null, () => start_test.begin ("extended"));
            if (!nvme) menu.add_item (_("Conveyance Test"), null, () => start_test.begin ("conveyance"));
            DisksWindow.show_menu (menu);
        }

        private async void start_test (string type) {
            try {
                yield drive.call (iface (), "SmartSelftestStart", new Variant ("(s@a{sv})", type, empty_options ()));
                yield refresh ();
            } catch (Error e) {
                show_error (e);
            }
        }

        private async void abort_test () {
            try {
                yield drive.call (iface (), "SmartSelftestAbort", new Variant ("(@a{sv})", empty_options ()));
            } catch (Error e) {
                show_error (e);
            }
        }

        private async void set_enabled (bool on) {
            if (on == drive.flag (IFACE_ATA, "SmartEnabled")) return;
            try {
                yield drive.call (IFACE_ATA, "SmartSetEnabled", new Variant ("(b@a{sv})", on, empty_options ()));
                yield load_attributes ();
            } catch (Error e) {
                show_error (e);
                enabled_switch.active = drive.flag (IFACE_ATA, "SmartEnabled");
            }
        }

        private async void refresh () {
            try {
                yield drive.call (iface (), "SmartUpdate", new Variant ("(@a{sv})", empty_options ()));
                error_label.visible = false;
            } catch (Error e) {
                show_error (e);
            }
            yield load_attributes ();
        }

        private void header (string[] titles) {
            for (int c = 0; c < titles.length; c++) {
                var l = new Label (titles[c]);
                l.xalign = 0;
                l.add_css_class ("heading");
                l.add_css_class ("caption");
                attributes.attach (l, c, 0, 1, 1);
            }
        }

        private void cell (int col, int row, string text, bool dim = false, string? css = null) {
            var l = new Label (text);
            l.xalign = 0;
            l.selectable = true;
            if (dim) l.add_css_class ("dim-label");
            if (css != null) l.add_css_class (css);
            attributes.attach (l, col, row, 1, 1);
        }

        private async void load_attributes () {
            Widget? child;
            while ((child = attributes.get_first_child ()) != null) attributes.remove (child);
            if (!nvme && !drive.flag (IFACE_ATA, "SmartEnabled")) return;
            Variant reply;
            try {
                reply = yield drive.call (iface (), "SmartGetAttributes", new Variant ("(@a{sv})", empty_options ()));
            } catch (Error e) {
                cell (0, 0, DisksWindow.describe_error (e), true);
                return;
            }
            if (nvme) {
                header ({ _("Attribute"), _("Value") });
                var dict = reply.get_child_value (0);
                int row = 1;
                var iter = dict.iterator ();
                string key;
                Variant val;
                while (iter.next ("{sv}", out key, out val)) {
                    string? name = nvme_name (key);
                    if (name == null) continue;
                    cell (0, row, name);
                    cell (1, row, nvme_value (key, val), true);
                    row++;
                }
                return;
            }
            header ({ _("ID"), _("Attribute"), _("Value"), _("Normalized"), _("Threshold"), _("Worst"), _("Assessment") });
            var list = reply.get_child_value (0);
            for (size_t n = 0; n < list.n_children (); n++) {
                var item = list.get_child_value (n);
                uint8 id = item.get_child_value (0).get_byte ();
                string name = item.get_child_value (1).get_string ();
                uint16 flags = item.get_child_value (2).get_uint16 ();
                int value = item.get_child_value (3).get_int32 ();
                int worst = item.get_child_value (4).get_int32 ();
                int threshold = item.get_child_value (5).get_int32 ();
                int64 pretty = item.get_child_value (6).get_int64 ();
                int unit = item.get_child_value (7).get_int32 ();
                int row = (int) n + 1;
                bool prefail = (flags & 1) != 0;
                string verdict = _("OK");
                string? css = null;
                if (value > 0 && threshold > 0 && value <= threshold) {
                    verdict = prefail ? _("Failing") : _("Worn Out");
                    css = "error";
                } else if (worst > 0 && threshold > 0 && worst <= threshold) {
                    verdict = _("Failed in the Past");
                    css = "warning";
                }
                cell (0, row, id.to_string (), true);
                cell (1, row, attribute_name (name));
                cell (2, row, pretty_value (pretty, unit));
                cell (3, row, value >= 0 ? value.to_string () : _("N/A"), true);
                cell (4, row, threshold >= 0 ? threshold.to_string () : _("N/A"), true);
                cell (5, row, worst >= 0 ? worst.to_string () : _("N/A"), true);
                cell (6, row, verdict, false, css);
            }
        }

        private string pretty_value (int64 pretty, int unit) {
            switch (unit) {
                case 2: return pretty < 1000 ? _("%lld ms").printf (pretty) : Format.duration (pretty / 1000);
                case 3: return ngettext ("%lld sector", "%lld sectors", (ulong) pretty).printf (pretty);
                case 4: return Format.temperature (pretty / 1000.0);
                default: return pretty.to_string ();
            }
        }

        private string attribute_name (string key) {
            switch (key) {
                case "raw-read-error-rate": return _("Read Error Rate");
                case "throughput-performance": return _("Throughput Performance");
                case "spin-up-time": return _("Spin-Up Time");
                case "start-stop-count": return _("Start/Stop Count");
                case "reallocated-sector-count": return _("Reallocated Sectors");
                case "seek-error-rate": return _("Seek Error Rate");
                case "power-on-hours": return _("Power-On Hours");
                case "spin-retry-count": return _("Spin Retry Count");
                case "power-cycle-count": return _("Power Cycles");
                case "temperature-celsius-2": case "temperature-celsius": case "airflow-temperature-celsius": return _("Temperature");
                case "reallocated-event-count": return _("Reallocation Events");
                case "current-pending-sector": return _("Pending Sectors");
                case "offline-uncorrectable": return _("Uncorrectable Sectors");
                case "udma-crc-error-count": return _("Cable Errors");
                case "power-off-retract-count": return _("Emergency Head Retracts");
                case "load-cycle-count": return _("Load Cycles");
                case "wear-leveling-count": return _("Wear Leveling");
                case "total-lbas-written": return _("Total Written");
                case "total-lbas-read": return _("Total Read");
                default: return key;
            }
        }

        private string? nvme_name (string key) {
            switch (key) {
                case "avail_spare": return _("Available Spare");
                case "spare_thresh": return _("Spare Threshold");
                case "percent_used": return _("Life Used");
                case "total_data_read": return _("Total Read");
                case "total_data_written": return _("Total Written");
                case "ctrl_busy_time": return _("Busy Time");
                case "power_cycles": return _("Power Cycles");
                case "unsafe_shutdowns": return _("Unsafe Shutdowns");
                case "media_errors": return _("Media Errors");
                case "num_err_log_entries": return _("Error Log Entries");
                case "wctemp": return _("Warning Temperature");
                case "cctemp": return _("Critical Temperature");
                case "warning_temp_time": return _("Time Above Warning Temperature");
                case "critical_temp_time": return _("Time Above Critical Temperature");
                default: return null;
            }
        }

        private string nvme_value (string key, Variant val) {
            uint64 n = 0;
            if (val.is_of_type (VariantType.BYTE)) n = val.get_byte ();
            else if (val.is_of_type (VariantType.UINT16)) n = val.get_uint16 ();
            else if (val.is_of_type (VariantType.UINT32)) n = val.get_uint32 ();
            else if (val.is_of_type (VariantType.UINT64)) n = val.get_uint64 ();
            else if (val.is_of_type (VariantType.INT32)) n = val.get_int32 ();
            else if (val.is_of_type (VariantType.INT64)) n = val.get_int64 ();
            else return val.print (false);
            switch (key) {
                case "avail_spare": case "spare_thresh": case "percent_used": return "%llu%%".printf (n);
                case "total_data_read": case "total_data_written": return Format.size (n);
                case "ctrl_busy_time": case "warning_temp_time": case "critical_temp_time": return Format.duration ((int64) n * 60);
                case "wctemp": case "cctemp": return Format.temperature ((double) n);
                default: return Format.group_digits (n);
            }
        }
    }
}
