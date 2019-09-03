{{ printf "%s/%s" .Values.conf.syslog.logpath .Values.conf.syslog.logfile }}
{
        rotate {{ .Values.conf.syslog.logrotate.rotate }}
        size {{ .Values.conf.syslog.logrotate.size }}
        missingok
        delaycompress
        compress
        nocreate
        nomail
        postrotate
                killall -s HUP rsyslogd >/dev/null 2>&1 || true
        endscript
}
