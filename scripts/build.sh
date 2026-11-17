#!/bin/bash
# Builds the signed APT repository into $OUT (default: public/).
#
#   pool/main/<p>/<package>/<package>_<version>_<arch>.deb
#   dists/stable/{InRelease,Release,Release.gpg}
#   dists/stable/main/binary-{amd64,arm64}/Packages(.gz)
#   be-spex-archive-keyring.{deb,gpg,asc}, bespex.gpg, index.html, state.txt
#
# Besides the app packages it builds its own: the keyring, the qiew metapackage
# (qiew/) and the codedeck metapackage (codedeck/).
#
# Packages come from the newest $KEEP stable releases of each entry in
# repos.json; only package names listed there are taken. A repository that
# releases several applications has one entry per application, told apart by
# the prefix of its release tags ("tagPrefix"). Signing uses the
# secret key in $GNUPGHOME (fingerprint $SIGNING_KEY, else the only one).
# Needs: gh (authenticated), jq, dpkg-deb, apt-ftparchive, gpg.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-public}
KEEP=${KEEP:-3}
SUITE=stable
ARCHS="amd64 arm64"
NAME=be-spex-archive-keyring

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rm -rf "$OUT"
mkdir -p "$OUT"

# Puts a .deb into the pool under its canonical name.
add_to_pool() {
    local deb=$1 pkg ver arch dir
    pkg=$(dpkg-deb -f "$deb" Package)
    ver=$(dpkg-deb -f "$deb" Version)
    arch=$(dpkg-deb -f "$deb" Architecture)
    dir="$OUT/pool/main/${pkg:0:1}/$pkg"
    mkdir -p "$dir"
    cp "$deb" "$dir/${pkg}_${ver}_${arch}.deb"
    echo "  $pkg $ver $arch"
}

# 1. App packages from the releases.
jq -c '.[]' repos.json | while read -r entry; do
    repo=$(jq -r .repo <<<"$entry")
    prefix=$(jq -r '.tagPrefix // ""' <<<"$entry")
    echo "$repo $prefix"
    # A repository this workflow cannot read (still private) is skipped; the others go on
    if ! tags=$(gh api "repos/$repo/releases?per_page=100" --jq \
        "[.[] | select(.draft | not) | select(.prerelease | not) | select(.tag_name | startswith(\"$prefix\"))] | .[:$KEEP][] | .tag_name" 2>/dev/null); then
        echo "  skipped: cannot read the releases of $repo"
        continue
    fi
    [ -n "$tags" ] || continue
    printf '%s\n' "$tags" |
    while read -r tag; do
        dl="$work/dl/$repo/$tag"
        mkdir -p "$dl"
        gh release download "$tag" -R "$repo" -p '*.deb' -D "$dl" 2>/dev/null || continue
        for deb in "$dl"/*.deb; do
            [ -e "$deb" ] || continue
            pkg=$(dpkg-deb -f "$deb" Package)
            if jq -e --arg p "$pkg" '.packages | index($p)' <<<"$entry" >/dev/null; then
                add_to_pool "$deb"
            else
                echo "  skipped $(basename "$deb") (package $pkg not listed for $repo)"
            fi
        done
    done
done

# 2. The keyring package: public key plus the APT source.
echo "keyring"
version=$(cat keyring/VERSION)
root="$work/keyring"
mkdir -p "$root/DEBIAN" "$root/usr/share/keyrings" "$root/etc/apt/sources.list.d"
gpg --dearmor < keys/$NAME.asc > "$root/usr/share/keyrings/$NAME.gpg"
cp keyring/be-spex.sources "$root/etc/apt/sources.list.d/be-spex.sources"
echo /etc/apt/sources.list.d/be-spex.sources > "$root/DEBIAN/conffiles"
cat > "$root/DEBIAN/control" <<EOF
Package: $NAME
Version: $version
Architecture: all
Maintainer: Bert Speckels <skrrytch@speckels.net>
Section: misc
Priority: optional
Homepage: https://bespex.run/apt/
Description: APT source and signing key of the be-spex packages
 Adds https://bespex.run/apt to APT and installs the key that
 signs it, so the be-spex applications (Marq, Xaq, Maillet, HatRack,
 PocketTray) can be installed and updated with apt.
EOF
find "$root" -type d -exec chmod 755 {} +
find "$root/usr" "$root/etc" -type f -exec chmod 644 {} +
dpkg-deb --root-owner-group --build "$root" "$work/$NAME.deb" >/dev/null
add_to_pool "$work/$NAME.deb"
cp "$work/$NAME.deb" "$OUT/$NAME.deb"
cp "$root/usr/share/keyrings/$NAME.gpg" "$OUT/$NAME.gpg"
cp "$OUT/$NAME.gpg" "$OUT/bespex.gpg"   # short alias of the binary key (APT before 2.4 needs this format)
cp keys/$NAME.asc "$OUT/$NAME.asc"

# 3. The qiew metapackage: recommends every Qiew viewer, brings qiew-setup.
# Its list must name only packages this repository has, or apt cannot install it.
echo "qiew"
listed=$(jq -r '.[] | select(.repo == "bespex/Qiew") | .packages[]' repos.json | sort)
recommended=$(sed -n 's/^Recommends: //p' qiew/control | tr ',' '\n' | awk '{print $1}' | sort)
if [ "$listed" != "$recommended" ]; then
    echo "qiew/control Recommends differs from the Qiew apps in repos.json:" >&2
    diff <(echo "$recommended") <(echo "$listed") >&2 || true
    exit 1
fi
root="$work/qiew"
mkdir -p "$root/DEBIAN" "$root/usr/bin"
cp qiew/control "$root/DEBIAN/control"
install -m 755 qiew/qiew-setup "$root/usr/bin/qiew-setup"
find "$root" -type d -exec chmod 755 {} +
dpkg-deb --root-owner-group --build "$root" "$work/qiew.deb" >/dev/null
add_to_pool "$work/qiew.deb"

# 3b. The codedeck metapackage: the program codeck plus the viewers CodeDeck
# opens things in. Built only once codeck itself is here, or apt could not
# install it; the same for every viewer it recommends.
codedeck_hint=""
if compgen -G "$OUT/pool/main/c/codeck/*.deb" >/dev/null; then
    echo "codedeck"
    have=$(jq -r '.[].packages[]' repos.json)
    for p in $(sed -n 's/^Recommends: //p' codedeck/control | tr ',' '\n' | awk '{print $1}'); do
        if ! grep -qx "$p" <<<"$have"; then
            echo "codedeck/control recommends $p, which repos.json does not list" >&2
            exit 1
        fi
    done
    root="$work/codedeck"
    mkdir -p "$root/DEBIAN"
    cp codedeck/control "$root/DEBIAN/control"
    find "$root" -type d -exec chmod 755 {} +
    dpkg-deb --root-owner-group --build "$root" "$work/codedeck.deb" >/dev/null
    add_to_pool "$work/codedeck.deb"
    codedeck_hint='<p>CodeDeck with the viewers it opens things in (Marq, Dirq, Jayq); the program alone is <code>codeck</code>:</p>\n  <pre>sudo apt install codedeck</pre>'
else
    echo "codedeck: skipped, codeck is not released yet"
fi

# 4. Indices and the signed Release file.
dist="$OUT/dists/$SUITE"
for arch in $ARCHS; do
    mkdir -p "$dist/main/binary-$arch"
    (cd "$OUT" && apt-ftparchive --arch "$arch" packages pool) > "$dist/main/binary-$arch/Packages"
    gzip -9kn "$dist/main/binary-$arch/Packages"
done
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=be-spex \
    -o APT::FTPArchive::Release::Label=be-spex \
    -o APT::FTPArchive::Release::Suite=$SUITE \
    -o APT::FTPArchive::Release::Codename=$SUITE \
    -o "APT::FTPArchive::Release::Architectures=$ARCHS" \
    -o APT::FTPArchive::Release::Components=main \
    -o "APT::FTPArchive::Release::Description=be-spex applications" \
    release "$dist" > "$work/Release"
mv "$work/Release" "$dist/Release"

key=${SIGNING_KEY:-$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')}
sign() { gpg --batch --yes --pinentry-mode loopback --passphrase '' --local-user "$key" "$@"; }
sign --clearsign -o "$dist/InRelease" "$dist/Release"
sign --armor --detach-sign -o "$dist/Release.gpg" "$dist/Release"

# 5. Landing page and state.
repo_of=$(jq -r '.[] | (.repo + (if .path then "/tree/main/" + .path else "" end)) as $r | .packages[] | "\(.)\t\($r)"' repos.json)
rows=$(cd "$OUT" && apt-ftparchive packages pool 2>/dev/null |
    awk -F': ' '/^Package:/ {p=$2} /^Version:/ {v=$2} /^Architecture:/ {a=$2}
                /^$/ {if (p) print p "\t" v "\t" a; p=v=a=""}' |
    sort -t$'\t' -k1,1 -k2,2Vr |
    awk -F'\t' -v map="$repo_of" '
        BEGIN { n = split(map, l, "\n"); for (i = 1; i <= n; i++) { split(l[i], f, "\t"); repo[f[1]] = f[2] } }
        { name = ($1 in repo) ? "<a href=\"https://github.com/" repo[$1] "\">" $1 "</a>" : $1
          printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", name, $2, $3, ($1 == prev ? "" : "latest")
          prev = $1 }')
sed "s|@ROWS@|$(printf '%s' "$rows" | sed 's/[&|]/\\&/g' | tr '\n' '\r')|; s|@CODEDECK@|$(printf '%b' "$codedeck_hint" | sed 's/[&|]/\\&/g' | tr '\n' '\r')|" scripts/index.html |
    tr '\r' '\n' > "$OUT/index.html"
scripts/state.sh > "$OUT/state.txt"
touch "$OUT/.nojekyll"
echo "done: $(find "$OUT/pool" -name '*.deb' | wc -l) packages"
