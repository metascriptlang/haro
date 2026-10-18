stty -icanon -echo min 0 time 3
printf '\033[>q'
reply=$(dd bs=256 count=1 2>/dev/null | tr '\033' '^')
stty sane
echo "reply=$reply"
