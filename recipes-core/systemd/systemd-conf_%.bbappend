do_install:append:aquila-am69() {
	sed -i '/^RuntimeWatchdogSec=/d' ${D}${systemd_unitdir}/system.conf.d/10-${BPN}.conf
}
