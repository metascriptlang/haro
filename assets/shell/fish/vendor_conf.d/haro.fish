if test -n "$HARO_XDG_DATA_DIRS"
    set -gx XDG_DATA_DIRS $HARO_XDG_DATA_DIRS
else
    set -e XDG_DATA_DIRS
end
set -e HARO_XDG_DATA_DIRS

status is-interactive; or exit
test (string replace -r '\..*' '' -- $version) -lt 4; or exit

function __haro_prompt --on-event fish_prompt
    set -l dir (string join / (string split / -- $PWD | string escape --style=url))
    printf '\e]7;file://%s%s\a\e]133;A\a' $hostname $dir
    if not functions -q __haro_user_prompt
        functions -c fish_prompt __haro_user_prompt
        function fish_prompt
            __haro_user_prompt
            printf '\e]133;B\a'
        end
    end
end

function __haro_preexec --on-event fish_preexec
    printf '\e]133;C;cmdline_url=%s\a' (string escape --style=url -- $argv[1])
end

function __haro_postexec --on-event fish_postexec
    set -l code $status
    printf '\e]133;D;%d\a' $code
end
