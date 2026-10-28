set +o posix
if [ -n "${HARO_ENV-}" ]; then
	ENV=$HARO_ENV
else
	unset ENV
fi
unset HARO_ENV

if shopt -q login_shell; then
	if [ -r /etc/profile ]; then . /etc/profile; fi
	if [ -r ~/.bash_profile ]; then
		. ~/.bash_profile
	elif [ -r ~/.bash_login ]; then
		. ~/.bash_login
	elif [ -r ~/.profile ]; then
		. ~/.profile
	fi
else
	if [ -r /etc/bash.bashrc ]; then . /etc/bash.bashrc; fi
	if [ -r ~/.bashrc ]; then . ~/.bashrc; fi
fi

. "${BASH_SOURCE[0]%/*}/haro.bash"
