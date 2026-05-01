# Airplanes.Live Feeder image update utility

This repository hosts the files needed to update the Airplanes.Live feeder image. If you wish to update your feeder, press the "Update Feeder" button, located on the "Update" page

## Legacy image bridge

This updater remains the compatibility path for already-shipped Airplanes.Live
images. It refreshes the legacy image stack, then delegates feed and MLAT setup
to `airplanes-live/feed/update.sh` so installed legacy-image users can receive
the current feed scripts, feeder ID handling, and feeder claim support.

The old image builder does not need to be changed for users who already have an
image installed. New image builds should use the feed repository's build-mode
installer directly instead of this updater's chroot path.
