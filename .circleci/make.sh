#!/bin/sh

DEST=config.gen.yml
ADHOC_MACHINE_EXS="tut-7 tut-7-rpc"

executor () {
  for ame in $ADHOC_MACHINE_EXS; do
    case "$ame" in
      "$1")
        echo "example-adhoc-machine"
        return
        ;;
    esac
  done
  echo "example-standard"
}

cat config.pre.yml > "${DEST}"
for ep in ../examples/* ; do
  if [ -d "${ep}" ] ; then

    e=$(basename "${ep}")
    cat >>"${DEST}" <<END
    - "$(executor "${e}")":
        name: "examples.${e}"
        which: "${e}"
        requires:
          - "build"
END
  fi
done

cat >>"${DEST}" <<END
    - "example-sink":
        requires:
END
for ep in ../examples/* ; do
  if [ -d "${ep}" ] ; then
    e=$(basename "${ep}")
    cat >>"${DEST}" <<END
          - "examples.${e}"
END
  fi
done
