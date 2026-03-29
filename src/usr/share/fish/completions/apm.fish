# APM 琥珀软件包管理器的 fish 自动补全

# 定义命令列表
set -l commands \
  ssaudit \
  ssinstall \
  launch \
  list \
  search \
  show \
  showsrc \
  install \
  remove \
  purge \
  autoremove \
  autopurge \
  update \
  upgrade \
  full-upgrade \
  dist-upgrade \
  run \
  sandbox-run \
  bwrap-run \
  help \
  source \
  build-dep \
  clean \
  autoclean \
  download \
  changelog \
  amber \
  xmp360 \
  bronya \
  debug \
  depends \
  rdepends \
  policy

# 定义通用选项
set -l options \
  -h \
  --help \
  --help-all \
  -v \
  --version

# 定义命令特定选项
set -l install_options \
  -d \
  --download-only \
  -y \
  --assume-yes \
  --assume-no \
  -u \
  --show-upgraded \
  -m \
  --ignore-missing \
  -t \
  --target-release \
  --download \
  --fix-missing \
  --ignore-hold \
  --upgrade \
  --only-upgrade \
  --allow-change-held-packages \
  --allow-remove-essential \
  --allow-downgrades \
  --print-uris \
  --trivial-only \
  --remove \
  --arch-only \
  --allow-unauthenticated \
  --allow-insecure-repositories \
  --install-recommends \
  --install-suggests \
  --no-install-recommends \
  --no-install-suggests \
  --fix-policy \
  --show-progress \
  --fix-broken \
  --purge \
  --verbose-versions \
  --auto-remove \
  -s \
  --simulate \
  --dry-run \
  --force-yes \
  --reinstall \
  --solver

set -l remove_options $install_options

set -l update_options \
  --list-cleanup \
  --print-uris \
  --allow-insecure-repositories

set -l list_options \
  --installed \
  --upgradable \
  --manual-installed \
  -v \
  --verbose \
  -a \
  --all-versions \
  -t \
  --target-release

set -l show_options \
  -a \
  --all-versions

set -l depends_options \
  -i \
  --important \
  --installed \
  --pre-depends \
  --depends \
  --recommends \
  --suggests \
  --replaces \
  --breaks \
  --conflicts \
  --enhances \
  --recurse \
  --implicit

set -l search_options \
  -n \
  --names-only \
  -f \
  --full

set -l showsrc_options \
  --only-source

set -l source_options $install_options \
  -b \
  --compile \
  --build \
  -P \
  --build-profiles \
  --diff-only \
  --debian-only \
  --tar-only \
  --dsc-only

set -l build_dep_options $install_options \
  -a \
  --host-architecture \
  -P \
  --build-profiles \
  --purge \
  --solver

set -l clean_options \
  -s \
  --simulate \
  --dry-run

set -l autoclean_options $clean_options

# 定义目录路径
set -l primary_dir "/var/lib/apm/apm/files/ace-env/var/lib/apm/"
set -l fallback_dir "/var/lib/apm/"

# 查找不包含特定子目录的目录
function find_directories_without_ace_env
  set -l base_dir $argv[1]
  set -l result
  
  # 检查基础目录是否存在
  if not test -d "$base_dir"
    return 1
  end
  
  # 查找所有直接子目录，排除包含ace-env子目录的目录
  for dir in "$base_dir"/*
    if test -d "$dir" && not test -d "$dir/files/ace-env"
      set result $result (basename "$dir")
    end
  end
  
  # 输出结果
  if test (count $result) -gt 0
    echo $result
    return 0
  end
  return 1
end

function apm_run_compgen
  set -l result (find_directories_without_ace_env "$primary_dir")

  if test -n "$result"
    echo $result
  else
    set result (find_directories_without_ace_env "$fallback_dir")
    if test -n "$result"
      echo $result
    else
      echo ""
    end
  end
end

# 主完成函数
complete -c apm -n "not __fish_seen_subcommand_from $commands" -a "$options" -d "选项"
complete -c apm -n "not __fish_seen_subcommand_from $commands" -a "$commands" -d "命令"

# 命令特定的完成
complete -c apm -n "__fish_seen_subcommand_from install" -a "$install_options" -d "选项"
complete -c apm -n "__fish_seen_subcommand_from install" -k -A "*.deb" -d "Deb 包"

complete -c apm -n "__fish_seen_subcommand_from remove purge autoremove autopurge" -a "$remove_options" -d "选项"
complete -c apm -n "__fish_seen_subcommand_from remove purge autoremove autopurge" -k -F "ls -1 $primary_dir 2>/dev/null || ls -1 $fallback_dir 2>/dev/null" -d "包"

complete -c apm -n "__fish_seen_subcommand_from update" -a "$update_options" -d "选项"

complete -c apm -n "__fish_seen_subcommand_from list" -a "$list_options" -d "选项"

complete -c apm -n "__fish_seen_subcommand_from show" -a "$show_options" -d "选项"
complete -c apm -n "__fish_seen_subcommand_from show" -k -F "amber-pm-debug apt-cache --no-generate pkgnames '' -o Dir::Cache=/var/lib/aptss/ 2>/dev/null" -d "包"

complete -c apm -n "__fish_seen_subcommand_from depends rdepends" -a "$depends_options" -d "选项"
complete -c apm -n "__fish_seen_subcommand_from depends rdepends" -k -F "amber-pm-debug apt-cache --no-generate pkgnames '' -o Dir::Cache=/var/lib/aptss/ 2>/dev/null" -d "包"

complete -c apm -n "__fish_seen_subcommand_from search" -a "$search_options" -d "选项"

complete -c apm -n "__fish_seen_subcommand_from showsrc" -a "$showsrc_options" -d "选项"
complete -c apm -n "__fish_seen_subcommand_from showsrc" -k -F "amber-pm-debug apt-cache --no-generate pkgnames '' -o Dir::Cache=/var/lib/aptss/ 2>/dev/null" -d "包"

complete -c apm -n "__fish_seen_subcommand_from source" -a "$source_options" -d "选项"
complete -c apm -n "__fish_seen_subcommand_from source" -k -F "amber-pm-debug apt-cache --no-generate pkgnames '' -o Dir::Cache=/var/lib/aptss/ 2>/dev/null" -d "包"

complete -c apm -n "__fish_seen_subcommand_from build-dep" -a "$build_dep_options" -d "选项"
complete -c apm -n "__fish_seen_subcommand_from build-dep" -k -F "amber-pm-debug apt-cache --no-generate pkgnames '' -o Dir::Cache=/var/lib/aptss/ 2>/dev/null" -d "包"

complete -c apm -n "__fish_seen_subcommand_from clean" -a "$clean_options" -d "选项"

complete -c apm -n "__fish_seen_subcommand_from autoclean" -a "$autoclean_options" -d "选项"

complete -c apm -n "__fish_seen_subcommand_from download changelog policy" -k -F "amber-pm-debug apt-cache --no-generate pkgnames '' -o Dir::Cache=/var/lib/aptss/ 2>/dev/null" -d "包"

complete -c apm -n "__fish_seen_subcommand_from run sandbox-run bwrap-run launch" -k -F "apm_run_compgen" -d "包"
complete -c apm -n "__fish_seen_subcommand_from run sandbox-run bwrap-run launch" -k -A "*" -d "文件"

complete -c apm -n "__fish_seen_subcommand_from ssaudit ssinstall" -k -A "*" -d "文件"
