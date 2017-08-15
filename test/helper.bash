#!/bin/bash

function export_env_vars {
	if [[ -n $BATS_TEST_DIRNAME ]]; then
		TESTDIR=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
	else
		TESTDIR=$(cd "$SCRIPTDIR" && pwd)
	fi
	export TESTDIR
	_TMPDIR=$(mktemp -d 2>/dev/null || mktemp -d -t homeshick)
	export _TMPDIR
	export REPO_FIXTURES="$_TMPDIR/repos"
	export HOME="$_TMPDIR/home"
	export NOTHOME="$_TMPDIR/nothome"
	export HOMESICK="$HOME/.homesick"

	export HOMESHICK_FN="homeshick"
	local repo_dir
	repo_dir=$(cd "$TESTDIR/.." && pwd)
	export HOMESHICK_DIR=${HOMESHICK_DIR:-$repo_dir}
	export HOMESHICK_FN_SRC_SH="$HOMESHICK_DIR/homeshick.sh"
	export HOMESHICK_FN_SRC_CSH="$HOMESHICK_DIR/bin/homeshick.csh"
	export HOMESHICK_FN_SRC_FISH="$HOMESHICK_DIR/homeshick.fish"
	export HOMESHICK_BIN="$HOMESHICK_DIR/bin/homeshick"

	# Check if expect is installed
	run type expect >/dev/null 2>&1
	if [[ $status != 0 ]]; then
		export EXPECT_INSTALLED=false
	else
		export EXPECT_INSTALLED=true
	fi
}

function remove_coreutils_from_path {
	# Check if coreutils is in PATH
	system=$(uname -a)
	if [[ $system =~ "Darwin" && ! $system =~ "AppleTV" ]]; then
		run type brew >/dev/null 2>&1
		if [[ $status = 0 ]]; then
			coreutils_path=$(brew --prefix coreutils 2>/dev/null)/libexec/gnubin
			if [[ -d $coreutils_path && $PATH == *$coreutils_path* ]]; then
				if [[ -z $HOMESHICK_KEEP_PATH || $HOMESHICK_KEEP_PATH == false ]]; then
					export PATH=${PATH//$coreutils_path/''}
					export PATH=${PATH//'::'/':'} # Remove any left over colons
				fi
			fi
		fi
	fi
}

function mk_structure {
	mkdir "$REPO_FIXTURES" "$HOME" "$NOTHOME"
}

function ln_homeshick {
	local hs_repo=$HOMESICK/repos/homeshick
	mkdir -p "$hs_repo"
	local repo_dir
	repo_dir=$(cd "$TESTDIR/.." && pwd)
	ln -s "$repo_dir/homeshick.sh" "$hs_repo/homeshick.sh"
	ln -s "$repo_dir/homeshick.fish" "$hs_repo/homeshick.fish"
	ln -s "$repo_dir/bin" "$hs_repo/bin"
	ln -s "$repo_dir/lib" "$hs_repo/lib"
	ln -s "$repo_dir/completions" "$hs_repo/completions"
}

function rm_structure {
	# Make sure _TMPDIR wasn't unset
	[[ -n $_TMPDIR ]] && rm -rf "$_TMPDIR"
}

function setup_env {
	remove_coreutils_from_path
	export_env_vars
	mk_structure
	# shellcheck source=homeshick.sh
	source "$HOMESHICK_FN_SRC_SH"
}

function setup {
	setup_env
}

function teardown {
	rm_structure
}

function fixture {
	local name=$1
	if [[ ! -e "$REPO_FIXTURES/$name" ]]; then
		# shellcheck disable=SC1090
		source "$TESTDIR/fixtures/$name.sh"
	fi
}

function castle {
	local fixture_name=$1
	fixture "$fixture_name"
	$HOMESHICK_FN --batch clone "$REPO_FIXTURES/$fixture_name" > /dev/null
}

function is_symlink {
	expected=$1
	path=$2
	target=$(readlink "$path")
	[ "$expected" = "$target" ]
}

function get_inode_no {
	stat -c %i "$1" 2>/dev/null || stat -f %i "$1"
}

# Snatched from http://stackoverflow.com/questions/4023830/bash-how-compare-two-strings-in-version-format
function version_compare {
	if [[ $1 == "$2" ]]; then
		return 0
	fi
	local IFS=.
	local i ver1=($1) ver2=($2)
	# fill empty fields in ver1 with zeros
	for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
		ver1[i]=0
	done
	for ((i=0; i<${#ver1[@]}; i++)); do
		if [[ -z ${ver2[i]} ]]; then
			# fill empty fields in ver2 with zeros
			ver2[i]=0
		fi
		if ((10#${ver1[i]} > 10#${ver2[i]})); then
			return 1
		fi
		if ((10#${ver1[i]} < 10#${ver2[i]})); then
			return 2
		fi
	done
	return 0
}

function get_git_version {
	GIT_VERSION=$(git --version | grep 'git version' | cut -d ' ' -f 3)
	[[ ! $GIT_VERSION =~ ([0-9]+)(\.[0-9]+){0,3} ]] && skip 'could not detect git version'
	printf "%s" "$GIT_VERSION"
}

function mock_git_version {
	# To mock a git version we simply create a function wrapper for it
	# and forward all calls to git except `git --version`
	local real_git
	real_git=$(which git)
	# Don't mess with quoting in this eval, it works...
	# shellcheck disable=SC2086
	eval "
		function git {
			if [[ \$1 == '--version' ]]; then
					echo "git version $1"
					return 0
				else
					local res
					# Some variable expansions used by git internally may break,
					# if we just forward the arguments with '\$@',
					# so we unset this function until the execution is completed.
					unset git
					$real_git "\$@"
					res=\$?
					mock_git_version $1
					return \$res
			fi
		}
	"
	# The functions need to be exported for them to work in child processes
	export -f git
	export -f mock_git_version
}

function commit_repo_state {
	local repo=$1
	(
		# Let cd just fail
		# shellcheck disable=SC2164
		cd "$repo"
		git config user.name "Homeshick user"
		git config user.email "homeshick@example.com"
		git add -A
		git commit -m "Commiting Repo State from test helper.bash."
	)
}
