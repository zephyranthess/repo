#!/bin/sh
# Rebuilds the Sileo repo index in docs/ from the .deb files in docs/debs/.
# Requires dpkg (brew install dpkg). Run from anywhere: scripts/update-repo.sh
set -e
cd "$(dirname "$0")/../docs"
dpkg-scanpackages -m debs /dev/null > Packages 2>/dev/null
bzip2 -kf Packages
gzip -kf Packages
cat > Release <<'REL'
Origin: zephyra
Label: zephyra
Suite: stable
Version: 1.0
Codename: ios
Architectures: iphoneos-arm64
Components: main
Description: CarCast (any app on CarPlay), LineFix and SpeedBoost.
REL
{
	echo "MD5Sum:"
	for f in Packages Packages.bz2 Packages.gz; do echo " $(md5 -q $f 2>/dev/null || md5sum $f | cut -d' ' -f1) $(wc -c < $f | tr -d ' ') $f"; done
	echo "SHA256:"
	for f in Packages Packages.bz2 Packages.gz; do echo " $(shasum -a 256 $f | cut -d' ' -f1) $(wc -c < $f | tr -d ' ') $f"; done
} >> Release
touch .nojekyll
echo "Repo index updated: $(grep -c '^Package:' Packages) packages"
