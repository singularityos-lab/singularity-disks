project('singularity-disks', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-disks"', language: 'c')
subdir('po')

gtk_dep   = dependency('gtk4')
gee_dep   = dependency('gee-0.8')
gio_dep   = dependency('gio-2.0')
gio_unix_dep = dependency('gio-unix-2.0')
posix_dep = meson.get_compiler('vala').find_library('posix')
m_dep     = meson.get_compiler('c').find_library('m', required: false)

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

core_sources = files(
  'src/format.vala',
)

executable('singularity-disks',
  core_sources + files(
    'src/main.vala',
    'src/app.vala',
    'src/udisks.vala',
    'src/window.vala',
    'src/volume_bar.vala',
    'src/dialogs.vala',
    'src/smart.vala',
    'src/benchmark.vala',
    'src/imaging.vala',
  ),
  dependencies: [gtk_dep, gee_dep, gio_dep, gio_unix_dep, posix_dep, m_dep, libsingularity_dep],
  install: true
)

shared_module('disks-removable',
  files('src/udisks.vala', 'plugin/removable.vala', 'plugin/removable_widget.vala', 'plugin/removable_plugin.vala'),
  dependencies: [gtk_dep, gee_dep, gio_dep, gio_unix_dep, posix_dep, libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'disks-removable'
)

install_data('plugin/disks-removable.plugin',
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'disks-removable'
)

format_test = executable('format-test',
  core_sources + files('tests/format_test.vala'),
  dependencies: [gee_dep, gio_dep],
)
test('format', format_test)

install_data('data/dev.sinty.disks.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/icons/dev.sinty.disks.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
