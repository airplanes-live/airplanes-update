#! /bin/bash


if [ $(id -u) -ne 0 ]; then
  echo -e "This script must be run as root. \n"
  exit 1
fi

echo -e "\n\n  APT clean"
apt autoremove -y
apt clean -y

echo -e "\n\n RESET UUID"
rm -f /boot/airplanes-uuid

echo -e "\n RESET SSH"
rm /etc/ssh/ssh_host_*

echo -e "\n REMOVE BASH HISTORY"
rm /home/pi/.bash_history

if ! [[ -d /airplanes/update/boot-configs ]]; then
    exit 1
fi

pushd /airplanes/update/boot-configs &>/dev/null
for file in *; do
    echo -e "\n RESET /boot/$file"
    cp --remove-destination -f -T "$file" "/boot/$file"
done
popd &>/dev/null

exit 0
