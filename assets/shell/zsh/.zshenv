if [[ -n ${HARO_ZDOTDIR-} ]]; then
	ZDOTDIR=$HARO_ZDOTDIR
else
	unset ZDOTDIR
fi
unset HARO_ZDOTDIR

if [[ -o interactive ]]; then
	_haro_url() {
		emulate -L zsh
		unsetopt multibyte
		local LC_ALL=C text=$1 out= c hex i
		for (( i = 1; i <= $#text; i++ )); do
			c=$text[i]
			if [[ $c == [A-Za-z0-9/._~-] ]]; then
				out+=$c
			else
				builtin printf -v hex '%%%02X' "'$c"
				out+=$hex
			fi
		done
		REPLY=$out
	}

	_haro_precmd() {
		local ret=$?
		emulate -L zsh
		if [[ -n ${_haro_ran-} ]]; then
			builtin printf '\e]133;D;%d\a' $ret
			_haro_ran=
		fi
		_haro_url $PWD
		builtin printf '\e]7;file://%s%s\a\e]133;A\a' $HOST $REPLY
		[[ $PS1 == *'133;B'* ]] || PS1=$PS1$'%{\e]133;B\a%}'
		return $ret
	}

	_haro_preexec() {
		emulate -L zsh
		_haro_url $1
		builtin printf '\e]133;C;cmdline_url=%s\a' $REPLY
		_haro_ran=1
	}

	autoload -Uz add-zsh-hook
	add-zsh-hook precmd _haro_precmd
	add-zsh-hook preexec _haro_preexec
fi

if [[ -f ${ZDOTDIR:-$HOME}/.zshenv ]]; then
	builtin source ${ZDOTDIR:-$HOME}/.zshenv
fi
