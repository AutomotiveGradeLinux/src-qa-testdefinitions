#!/bin/bash

set -x

( echo "nameserver 8.8.8.8" > /etc/resolv.conf ) || true

export TERM=dumb
export COLUMNS=1000

SCRIPTDIR=`dirname $(readlink -f $0)`
XDG_RUNTIME_DIR=/run/user/1001
AGLDRIVER=agl-driver

if [ -z $1 ] ; then
    echo "No reference image passed"
    exit 125
fi

REF_IMAGE=`readlink -f $1`

# go to output directory
cd /home/$AGLDRIVER




if [ -z "${REF_IMAGE}" ]; then
	echo "No reference image passed"
	exit 125
fi

if [ ! -f "${REF_IMAGE}" ]; then
	echo "Reference image is not found"
	exit 125
fi

HOMESCREEN=homescreen
if [ -f /usr/lib/systemd/system/flutter-ics-homescreen.service ]; then
    HOMESCREEN=flutter-ics-homescreen
fi

# Enable the test picture and disable cursor and any other application from being displayed
sed -i '/^\[core\]/a activate-by-default=false' /etc/xdg/weston/weston.ini
# setup homescreen env variable
sed -i '/^\[core\]/a hide-cursor=true' /etc/xdg/weston/weston.ini
# enable red/green/blue test screen
echo 'HOMESCREEN_DEMO_CI=1' > /etc/default/$HOMESCREEN

# debug
echo 'WAYLAND_DEBUG=1' >> /etc/default/agl-compositor
sync
systemctl daemon-reload || true
sleep 2

# create initial journal cursor file
journalctl /usr/bin/agl-compositor --cursor-file=/tmp/agl-screenshot-cursor > /tmp/first-log 2>&1

# stop homescreen (shell) and launcher
systemctl stop $HOMESCREEN.service
if [ "$HOMESCREEN" = "homescreen" ]; then
    systemctl stop launcher.service
fi
# restart agl-compositor
systemctl restart agl-compositor.service
systemctl start $HOMESCREEN.service

# e.g. qemu-system-arm takes loooong
sleep 15
echo "Waiting for compositor to initialize (+20sec)."

LOOP=20
while test $LOOP -ge 1 ; do

  ( mv /tmp/next-log /tmp/prev-log > /dev/null 2>&1 ) || true
  journalctl /usr/bin/agl-compositor --cursor-file=/tmp/agl-screenshot-cursor > /tmp/next-log 2>&1
  if ! grep -q 'Usable area:' /tmp/next-log ; then
  # e.g. qemu-system-arm takes loooong
        echo "Waiting for compositor to initialize (+60sec). Loop: $LOOP"
	sleep 60
	LOOP="$(($LOOP-1))"
	continue
  fi
  break
done

#read aw


# giving up now
if ! grep -q 'Usable area:' /tmp/next-log ; then
	echo "Marker ('Usable area:') not found. Dumping log."
	echo "##################################"
	cat /tmp/first-log
	cat /tmp/prev-log
	cat /tmp/next-log
	echo "##################################"
        exit 127
	#echo "CONTINUING ANYWAY !"
fi

AGL_SCREENSHOOTER=/usr/bin/agl-screenshooter


#su - $AGLDRIVER -c "..."
do_screenshot()
{
	$AGL_SCREENSHOOTER -a
	return $?
}


if [ -z "$AGL_SCREENSHOOTER" ]; then
	echo "Failed to find agl-screenshooter. Compositor too old?"
	exit 127
fi

#echo "Found agl-screenshoooter in $AGL_SCREENSHOOTER"
rm -rf /home/agl-driver/agl-screenshot-*.png

# give it a bit more time to display
sleep 15

$AGL_SCREENSHOOTER -l

if do_screenshot ; then
	echo "Screenshot taken"
else
	echo "##################################"
	journalctl --no-pager -a -b /usr/bin/agl-compositor
	echo "##################################"
	exit 127
fi

ls agl-screenshot*

REF_IMAGE_SHA1SUM=`sha1sum ${REF_IMAGE} | awk -F ' ' '{print $1}'`

FINALRET=1


for SCREENSHOT in agl-screenshot-*.png ; do
    IMAGE_SHA1SUM=`sha1sum $SCREENSHOT | awk -F ' ' '{print $1}'`

    if [ "${REF_IMAGE_SHA1SUM}" == "${IMAGE_SHA1SUM}" ]; then
	echo "A Screenshot matches the reference image"
	FINALRET=0
	break
    else
	echo "A Screenshot does not match the reference image"
	curl -F "file=@./${SCREENSHOT}" https://x0.at/ || true
	FINALRET=127
    fi
done



if [ $FINALRET != 0 ] ; then
    for i in agl-screenshot-*.png ; do
	${SCRIPTDIR}/./artiproxy-upload.sh $i "$i"
    done
    journalctl -b --no-pager -a > journal.txt
    ${SCRIPTDIR}/./artiproxy-upload.sh journal.txt journal.txt

    echo "#########################"
    cat /run/platform/display/*.log
    echo "#########################"
    set
    echo "#########################"
fi

# cleanup
sed -i '/activate-by-default=false/d' /etc/xdg/weston/weston.ini
sed -i '/hide-cursor=true/d' /etc/xdg/weston/weston.ini
#rm -rf /etc/systemd/system/weston@.service.d
rm -rf /etc/default/$HOMESCREEN
systemctl daemon-reload
sync
sleep 2
systemctl restart agl-compositor.service
systemctl restart $HOMESCREEN.service
if [ "$HOMESCREEN" = "homescreen" ]; then
    systemctl restart launcher.service
fi

sleep 10

exit $FINALRET
