#!/bin/sh

export PAGER=/bin/cat
case $( . /etc/os-release; echo $NAME ) in
    FreeBSD)
        freebsd-update --not-running-from-cron fetch install
    ;&
    CheriBSD)
        echo skipped freebsd-update for CheriBSD
    ;;
esac
