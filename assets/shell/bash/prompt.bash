_haro_boot_last=
case $PROMPT_COMMAND in
	*"$HARO_BASH_BOOT") _haro_boot_last=1 ;;
esac
PROMPT_COMMAND=${PROMPT_COMMAND/"$HARO_BASH_BOOT"/:}
if [ -z "${HARO_PROMPT_COMMAND-}" ]; then export -n PROMPT_COMMAND; fi
unset HARO_BASH_BOOT HARO_PROMPT_COMMAND
. "${BASH_SOURCE[0]%/*}/haro.bash"
_haro_prompt
if [ -n "$_haro_boot_last" ]; then _haro_ready; fi
