using Singularity.Apps.Disks;

void test_group_digits () {
    assert (Format.group_digits (0) == "0");
    assert (Format.group_digits (999) == "999");
    assert (Format.group_digits (1000) == "1,000");
    assert (Format.group_digits (1234567890) == "1,234,567,890");
}

void test_parse_size () {
    assert (Format.parse_size ("1,5", 1000) == 1500);
    assert (Format.parse_size ("2", 1000000) == 2000000);
    assert (Format.parse_size ("-3", 1000) == 0);
    assert (Format.parse_size ("abc", 1000) == 0);
}

void test_names () {
    assert (Format.filesystem_name ("ext4") == "Ext4");
    assert (Format.filesystem_name ("vfat", "FAT32") == "FAT (FAT32)");
    assert (Format.gpt_type_name ("C12A7328-F81F-11D2-BA4B-00A0C93EC93B") == "EFI System");
    assert (Format.dos_type_name ("0x83") == "Linux");
    assert (Format.dos_type_name ("0x5") == "Extended");
    assert (Format.dos_type_name ("0x99") == "0x99");
}

void test_options () {
    var options = Format.options ();
    bool has_luks = false;
    foreach (var o in options) {
        if (o.encrypted) {
            has_luks = true;
            assert (o.fs_type == "ext4");
        }
        assert (o.label_max >= 0);
    }
    assert (has_luks);
    foreach (string id in Format.gpt_types ()) assert (Format.gpt_type_name (id) != id);
    foreach (string id in Format.dos_types ()) assert (!Format.dos_type_name (id).has_prefix ("0x"));
}

void test_temperature () {
    assert (Format.temperature (0) == "");
    assert (Format.temperature (273.15 + 40) == "40 °C");
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "C");
    Test.init (ref args);
    Test.add_func ("/format/group-digits", test_group_digits);
    Test.add_func ("/format/parse-size", test_parse_size);
    Test.add_func ("/format/names", test_names);
    Test.add_func ("/format/options", test_options);
    Test.add_func ("/format/temperature", test_temperature);
    return Test.run ();
}
