namespace Singularity.Apps.Disks {

    public class FsOption : Object {
        public string id;
        public string label;
        public string detail;
        public string fs_type;
        public bool encrypted;
        public int label_max;

        public FsOption (string id, string label, string detail, string fs_type, bool encrypted, int label_max) {
            this.id = id;
            this.label = label;
            this.detail = detail;
            this.fs_type = fs_type;
            this.encrypted = encrypted;
            this.label_max = label_max;
        }
    }

    public class Format : Object {
        public static string size (uint64 bytes) {
            return GLib.format_size (bytes);
        }

        public static string size_long (uint64 bytes) {
            return _("%s (%s bytes)").printf (GLib.format_size (bytes), group_digits (bytes));
        }

        public static string group_digits (uint64 value) {
            string digits = value.to_string ();
            var builder = new StringBuilder ();
            int count = 0;
            for (int i = digits.length - 1; i >= 0; i--) {
                builder.prepend_c (digits[i]);
                if (++count % 3 == 0 && i > 0) builder.prepend_c (',');
            }
            return builder.str;
        }

        public static uint64 parse_size (string text, uint64 unit) {
            string clean = text.strip ().replace (",", ".");
            double value = double.parse (clean);
            if (value <= 0) return 0;
            return (uint64) (value * unit);
        }

        public static Gee.List<FsOption> options () {
            var list = new Gee.ArrayList<FsOption> ();
            list.add (new FsOption ("ext4", _("Linux (Ext4)"), _("For Linux systems and internal drives"), "ext4", false, 16));
            list.add (new FsOption ("luks-ext4", _("Encrypted Linux (LUKS + Ext4)"), _("Protected by a passphrase, for Linux systems"), "ext4", true, 16));
            list.add (new FsOption ("btrfs", _("Btrfs"), _("Snapshots and checksums, for Linux systems"), "btrfs", false, 255));
            list.add (new FsOption ("xfs", _("XFS"), _("Large files and servers, for Linux systems"), "xfs", false, 12));
            list.add (new FsOption ("exfat", _("exFAT"), _("Works on Linux, Windows and macOS, large files"), "exfat", false, 15));
            list.add (new FsOption ("vfat", _("FAT32"), _("Works almost everywhere, files up to 4 GB"), "vfat", false, 11));
            list.add (new FsOption ("ntfs", _("NTFS"), _("For Windows systems"), "ntfs", false, 128));
            list.add (new FsOption ("swap", _("Swap"), _("Extra memory for Linux"), "swap", false, 15));
            list.add (new FsOption ("empty", _("No Filesystem"), _("Leave the space empty"), "empty", false, 0));
            return list;
        }

        public static string filesystem_name (string id_type, string id_version = "") {
            switch (id_type) {
                case "ext2": return "Ext2";
                case "ext3": return "Ext3";
                case "ext4": return "Ext4";
                case "btrfs": return "Btrfs";
                case "xfs": return "XFS";
                case "vfat": return id_version != "" ? "FAT (%s)".printf (id_version) : "FAT";
                case "exfat": return "exFAT";
                case "ntfs": return "NTFS";
                case "swap": return _("Swap");
                case "crypto_LUKS": return id_version != "" ? _("LUKS Encryption (version %s)").printf (id_version) : _("LUKS Encryption");
                case "LVM2_member": return _("LVM Physical Volume");
                case "linux_raid_member": return _("RAID Member");
                case "iso9660": return _("ISO 9660");
                case "udf": return "UDF";
                case "hfsplus": return "HFS+";
                case "apfs": return "APFS";
                case "f2fs": return "F2FS";
                case "squashfs": return "SquashFS";
                case "erofs": return "EROFS";
                case "zfs_member": return _("ZFS Member");
                case "bitlocker": return _("BitLocker Encryption");
                case "": return _("Unknown");
                default: return id_type;
            }
        }

        public static string gpt_type_name (string guid) {
            switch (guid.down ()) {
                case "c12a7328-f81f-11d2-ba4b-00a0c93ec93b": return _("EFI System");
                case "21686148-6449-6e6f-744e-656564454649": return _("BIOS Boot");
                case "0fc63daf-8483-4772-8e79-3d69d8477de4": return _("Linux Filesystem");
                case "4f68bce3-e8cd-4db1-96e7-fbcaf984b709": return _("Linux Root (x86-64)");
                case "933ac7e1-2eb4-4f13-b844-0e14e2aef915": return _("Linux Home");
                case "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f": return _("Linux Swap");
                case "e6d6d379-f507-44c2-a23c-238f2a3df928": return _("Linux LVM");
                case "a19d880f-05fc-4d3b-a006-743f0f84911e": return _("Linux RAID");
                case "ca7d7ccb-63ed-4c53-861c-1742536059cc": return _("Linux LUKS");
                case "bc13c2ff-59e6-4262-a352-b275fd6f7172": return _("Linux Extended Boot");
                case "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7": return _("Basic Data");
                case "e3c9e316-0b5c-4db8-817d-f92df00215ae": return _("Microsoft Reserved");
                case "de94bba4-06d1-4d40-a16a-bfd50179d6ac": return _("Windows Recovery");
                case "48465300-0000-11aa-aa11-00306543ecac": return _("Apple HFS+");
                case "7c3457ef-0000-11aa-aa11-00306543ecac": return _("Apple APFS");
                default: return guid;
            }
        }

        public static string dos_type_name (string code) {
            string c = code.down ();
            if (c.has_prefix ("0x")) c = c.substring (2);
            switch (c) {
                case "83": return _("Linux");
                case "82": return _("Linux Swap");
                case "8e": return _("Linux LVM");
                case "fd": return _("Linux RAID");
                case "5": case "05": return _("Extended");
                case "f": case "0f": return _("Extended (LBA)");
                case "85": return _("Linux Extended");
                case "7": case "07": return _("NTFS / exFAT");
                case "b": case "0b": return _("FAT32");
                case "c": case "0c": return _("FAT32 (LBA)");
                case "e": case "0e": return _("FAT16 (LBA)");
                case "ef": return _("EFI System");
                case "ee": return _("GPT Protective");
                default: return "0x" + c;
            }
        }

        public static string[] gpt_types () {
            return {
                "0fc63daf-8483-4772-8e79-3d69d8477de4", "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
                "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7", "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f",
                "933ac7e1-2eb4-4f13-b844-0e14e2aef915", "ca7d7ccb-63ed-4c53-861c-1742536059cc",
                "e6d6d379-f507-44c2-a23c-238f2a3df928", "a19d880f-05fc-4d3b-a006-743f0f84911e",
                "21686148-6449-6e6f-744e-656564454649"
            };
        }

        public static string[] dos_types () {
            return { "0x83", "0x0c", "0x07", "0x82", "0xef", "0x8e", "0xfd", "0x05" };
        }

        public static string duration (int64 seconds) {
            if (seconds < 60) return ngettext ("%lld second", "%lld seconds", (ulong) seconds).printf (seconds);
            int64 minutes = seconds / 60;
            if (minutes < 60) return ngettext ("%lld minute", "%lld minutes", (ulong) minutes).printf (minutes);
            int64 hours = minutes / 60;
            if (hours < 48) return ngettext ("%lld hour", "%lld hours", (ulong) hours).printf (hours);
            int64 days = hours / 24;
            if (days < 730) return ngettext ("%lld day", "%lld days", (ulong) days).printf (days);
            return ngettext ("%lld year", "%lld years", (ulong) (days / 365)).printf (days / 365);
        }

        public static string temperature (double kelvin) {
            if (kelvin <= 0) return "";
            return "%.0f °C".printf (kelvin - 273.15);
        }

        public static string rate (double bytes_per_second) {
            return _("%s/s").printf (GLib.format_size ((uint64) bytes_per_second));
        }
    }
}
