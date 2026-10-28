_haro_url() {
	local LC_ALL=C text=$1 out= c code hex i
	for (( i = 0; i < ${#text}; i++ )); do
		c=${text:i:1}
		case $c in
			[A-Za-z0-9/._~-]) out+=$c ;;
			*)
				builtin printf -v code '%d' "'$c"
				builtin printf -v hex '%%%02X' $(( code & 255 ))
				out+=$hex
				;;
		esac
	done
	_haro_reply=$out
}

_haro_prompt() {
	_haro_status=$?
	_haro_at_prompt=
	if [ -n "${_haro_ran-}" ]; then
		builtin printf '\033]133;D;%d\007' "$_haro_status"
		_haro_ran=
	fi
	_haro_url "$PWD"
	builtin printf '\033]7;file://%s%s\007\033]133;A\007' "$HOSTNAME" "$_haro_reply"
	case $PS1 in
		*'133;B'*) ;;
		*) PS1=$PS1'\[\033]133;B\007\]' ;;
	esac
	return $_haro_status
}

_haro_newest() {
	local entry
	entry=$(HISTTIMEFORMAT= builtin history 1)
	entry=${entry#"${entry%%[! ]*}"}
	_haro_number=${entry%%[!0-9]*}
	entry=${entry#"$_haro_number"}
	_haro_entry=${entry#"${entry%%[!* ]*}"}
}

_haro_ready() {
	if [ -z "${_haro_history+set}" ]; then
		_haro_newest
		_haro_history=$_haro_number
	fi
	_haro_at_prompt=1
	return $_haro_status
}

_haro_preexec() {
	[ -n "${_haro_at_prompt-}" ] && [ -z "${COMP_LINE-}" ] || return
	_haro_newest
	if [ "$BASH_COMMAND" = _haro_prompt ]; then
		[ -n "$_haro_number" ] && [ "$_haro_number" != "$_haro_history" ] || return
	elif [ -z "$_haro_number" ] || [ "$_haro_number" = "$_haro_history" ]; then
		_haro_entry=$BASH_COMMAND
	fi
	_haro_at_prompt=
	_haro_history=$_haro_number
	_haro_url "$_haro_entry"
	builtin printf '\033]133;C;cmdline_url=%s\007' "$_haro_reply"
	_haro_ran=1
}

if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
	PROMPT_COMMAND=(_haro_prompt "${PROMPT_COMMAND[@]}" _haro_ready)
else
	PROMPT_COMMAND=$'_haro_prompt\n'"${PROMPT_COMMAND-}"$'\n_haro_ready'
fi
if [ -z "$(trap -p DEBUG)" ]; then
	trap '_haro_preexec' DEBUG
fi
