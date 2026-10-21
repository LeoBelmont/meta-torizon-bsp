# nvidia-docker (removed upstream in meta-tegra ff3e10306b8a) used to ship its
# own /etc/docker/daemon.json registering the "nvidia" runtime.
# The OS no longer ships nvidia-container-toolkit: "nvidia" is
# nvidia-torizon-runtime, which pulls and starts the nvidia-l4t-driver container
# on the first GPU container and delegates to the toolkit's runtime inside it.
# Register it here, without making it the default, by overriding
# the vendor daemon.json this recipe installs - the stanza is static, so it
# belongs in the build-time file, not written to /etc by a device-side
# nvidia-ctk run. /etc/docker/daemon.json is OSTree-persistent state: once a
# device seeds it, it never picks up a later change to the vendor default
# again, since dockerd's own fallback patch only reads /usr/lib/docker/
# daemon.json when /etc/docker/daemon.json is absent.
FILESEXTRAPATHS:prepend := "${THISDIR}/${BPN}:"
