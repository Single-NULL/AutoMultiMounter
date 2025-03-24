#!/bin/bash
# forensic_mount_dynamic_robust.sh

# if [ "$EUID" -ne 0 ]
#  then echo "Please run as root"
 # exit
#fi

#
# Beschrijving:
# Dit script mount forensische images (E01, dd, raw) op een dynamische en robuuste manier.
# - Het controleert met 'parted' en 'file' of er een partition table aanwezig is.
# - Indien een partition table aanwezig is, wordt met 'kpartx' geprobeerd alle partities te mappen.
# - De script-modus (auto, raid, single) kan via een optionele parameter worden ingesteld.
#   In auto-mode wordt bepaald of de images samengehangen (raid) of afzonderlijk (single) moeten worden behandeld.
# - Alle mount directories worden dynamisch aangemaakt op basis van de basename van de image.
# - Via trap worden bij interrupts en fouten alle mounts, loop devices en RAID-arrays automatisch opgeschoond.
#
# Gebruik:
#   ./$(basename "$0") [--help|-h] [--mode <auto|raid|single>] <image_file1> [<image_file2> ... <image_fileN>]

#####################################
# Helpfunctie
#####################################
usage() {
    cat << EOF
Gebruik: $(basename "$0") [--help|-h] [--mode <auto|raid|single>] <image_file1> [<image_file2> ... <image_fileN>]

Beschrijving:
  Dit script mount forensische images. Afhankelijk van de modus:
    - single: Mount elk image afzonderlijk. Er wordt eerst gecontroleerd of er een partition table aanwezig is.
              Indien ja, worden de partities (bij voorkeur de eerste) via kpartx of direct gemount;
              anders wordt het gehele loop device gemount.
    - raid: De opgegeven images worden samengevoegd via mdadm tot één RAID-array, waarna de array gemount wordt.
    - auto (standaard): Bij één image wordt single gebruikt.
         Bij meerdere images wordt gecontroleerd op een gemeenschappelijke prefix (en eventueel met extra metadata)
         om te bepalen of ze als samenhangende onderdelen (raid) of afzonderlijk moeten worden gemount.
         
Opties:
  --help, -h         Toon deze helptekst en sluit af.
  --mode <mode>      Forceer de modus: auto, raid of single. (Standaard is auto)

Voorbeelden:
  Mount een enkele E01-image:
    $(basename "$0") /pad/naar/carimage.E01

  Mount een dd/raw-image:
    $(basename "$0") /pad/naar/driverbox.dd

  Assembleer een RAID-array van meerdere images:
    $(basename "$0") --mode raid /pad/naar/carimage1.E01 /pad/naar/carimage2.E01

  Laat het script automatisch bepalen (auto mode):
    $(basename "$0") /pad/naar/diskimage.E01 /pad/naar/diskimage.E02

EOF
    exit 0
}

#####################################
# Globale variabelen en standaardinstellingen
#####################################
MODE="auto"
SELECTED_MODE=""
GLOBAL_LOOP_DEVICES=()  # Houdt alle gekoppelde loop devices bij
GLOBAL_MOUNT_DIRS=()    # Houdt alle aangemaakte mount directories bij
RAID_DEVICE="/dev/md0"

#####################################
# Cleanup-functie: Ruim alle resources op
#####################################
cleanup() {
    echo "[INFO] Start cleanup procedure..."

    # Stop eventueel bestaande RAID-array
    if [ -e "$RAID_DEVICE" ]; then
        echo "[INFO] Stoppen van RAID-array $RAID_DEVICE"
        sudo mdadm --stop "$RAID_DEVICE" 2>/dev/null
    fi

    # Unmount alle mappen
    for mnt in "${GLOBAL_MOUNT_DIRS[@]}"; do
        if mountpoint -q "$mnt"; then
            echo "[INFO] Unmounten van $mnt"
            sudo umount "$mnt" 2>/dev/null
        fi
    done

    # Ontkoppel alle loop devices
    for loopdev in "${GLOBAL_LOOP_DEVICES[@]}"; do
        if [ -b "$loopdev" ]; then
            echo "[INFO] Loskoppelen van loop device $loopdev"
            sudo losetup -d "$loopdev" 2>/dev/null
        fi
    done

    # Indien kpartx mappings zijn aangemaakt, verwijder deze
    if command -v kpartx >/dev/null 2>&1; then
        for loopdev in "${GLOBAL_LOOP_DEVICES[@]}"; do
            echo "[INFO] Verwijderen van kpartx mappings voor $loopdev"
            sudo kpartx -d "$loopdev" 2>/dev/null
        done
    fi
}
trap cleanup EXIT SIGINT SIGTERM ERR

#####################################
# Controleer vereiste commando's
#####################################
for cmd in ewfmount losetup mount mdadm lsblk parted file; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] $cmd is niet geïnstalleerd. Installeer dit en probeer opnieuw."; exit 1; }
done

# kpartx is optioneel maar aanbevolen voor complexere layouts
if ! command -v kpartx >/dev/null 2>&1; then
    echo "[WARNING] kpartx is niet gevonden; complexere partitie-indelingen worden mogelijk niet automatisch gedetecteerd."
fi

#####################################
# Functie: Detecteer of een loop device een partition table bevat.
# Gebruik 'parted' en 'file' voor een uitgebreide controle.
# Retourneert 0 als er een partition table is, anders 1.
#####################################
detect_partition_table() {
    local loop_dev="$1"
    local parted_out
    parted_out=$(sudo parted -s "$loop_dev" print 2>/dev/null)
    if echo "$parted_out" | grep -q "Partition Table:"; then
        # Gebruik 'file' voor extra zekerheid: controleer op bekende signatures (MBR, GPT)
        local file_out
        file_out=$(sudo file -s "$loop_dev")
        if echo "$file_out" | grep -qiE "dos/mbR|gpt"; then
            return 0
        fi
    fi
    return 1
}

#####################################
# Functie: Activeer kpartx om partities te mappen en retourneer de mapping voor de eerste partitie.
# Indien kpartx niet beschikbaar of mapping mislukt, retourneer een lege string.
#####################################
map_partitions() {
    local loop_dev="$1"
    local mapping=""
    if command -v kpartx >/dev/null 2>&1; then
        local kpartx_out
        kpartx_out=$(sudo kpartx -av "$loop_dev" 2>/dev/null)
        if [ $? -eq 0 ]; then
            # Verwacht output zoals: "add map loop0p1 (254:0): 0 409600 linear /dev/loop0 2048"
            mapping=$(echo "$kpartx_out" | grep -oE "/dev/mapper/[^ ]+p1")
        fi
    fi
    echo "$mapping"
}

#####################################
# Functie: Bepaal een gemeenschappelijke prefix voor meerdere bestandsnamen.
# Retourneert "raid" als alle basenames een gemeenschappelijke prefix hebben, anders "single".
#####################################
determine_auto_mode() {
    local files=("$@")
    if [ "${#files[@]}" -eq 1 ]; then
        echo "single"
        return
    fi
    local common_prefix="${files[0]##*/}"
    common_prefix="${common_prefix%.*}"
    for file in "${files[@]:1}"; do
        local base
        base=$(basename "$file")
        base="${base%.*}"
        # Vergelijk een gedeeld deel, bijvoorbeeld de eerste 5 tekens
        if [[ "${base:0:5}" != "${common_prefix:0:5}" ]]; then
            echo "single"
            return
        fi
    done
    echo "raid"
}

#####################################
# Functie: Mount een enkel image.
#
# - Voor E01-images wordt eerst met ewfmount gewerkt.
# - Voor dd/raw-images wordt direct losetup gebruikt.
# - Vervolgens wordt gecontroleerd of er een partition table aanwezig is:
#     * Indien ja, wordt geprobeerd met kpartx de partities te mappen en de eerste partitie te mounten.
#     * Indien nee, wordt het gehele loop device gemount.
#
# Argument:
#   $1: pad naar de image
# Retourneert: het toegewezen loop device.
#####################################
mount_single_image() {
    local image_file="$1"

    if [ ! -f "$image_file" ]; then
         echo "[ERROR] Bestand $image_file bestaat niet." >&2
         exit 1
    fi

    local filename base extension
    filename=$(basename "$image_file")
    base="${filename%.*}"
    extension=$(echo "${filename##*.}" | tr '[:upper:]' '[:lower:]')
    local loop_device=""
    local mount_dir=""
    local part_mount=""

    if [[ "$extension" == "e01" ]]; then
         mount_dir="/mnt/${base}_mount"
         echo "[INFO] E01 gedetecteerd. Creëren van mount-directory: $mount_dir"
         mkdir -p "$mount_dir" || { echo "[ERROR] Kan $mount_dir niet aanmaken." >&2; exit 1; }
         GLOBAL_MOUNT_DIRS+=("$mount_dir")
         echo "[INFO] Mounten van E01 image '$image_file' naar '$mount_dir'"
         sudo ewfmount "$image_file" "$mount_dir" || { echo "[ERROR] ewfmount mislukt voor $image_file." >&2; exit 1; }
         local ewf_file="${mount_dir}/ewf1"
         if [ ! -f "$ewf_file" ]; then
              echo "[ERROR] Bestand $ewf_file niet gevonden in $mount_dir." >&2
              exit 1
         fi
         echo "[INFO] Koppelen van '$ewf_file' aan een loopback-device"
         loop_device=$(sudo losetup -Pf --show "$ewf_file") || { echo "[ERROR] Losetup mislukt voor $ewf_file." >&2; exit 1; }
         echo "[INFO] Toegewezen loopback-device: $loop_device"
    elif [[ "$extension" == "dd" || "$extension" == "raw" ]]; then
         echo "[INFO] dd/raw image gedetecteerd: '$image_file'"
         loop_device=$(sudo losetup -Pf --show "$image_file") || { echo "[ERROR] Losetup mislukt voor $image_file." >&2; exit 1; }
         echo "[INFO] Toegewezen loopback-device: $loop_device"
    else
         echo "[ERROR] Onbekende extensie '$extension' voor bestand '$image_file'." >&2
         exit 1
    fi

    GLOBAL_LOOP_DEVICES+=("$loop_device")

    # In single mode: probeer de partitie te mounten
    if [ "$SELECTED_MODE" = "single" ]; then
         if detect_partition_table "$loop_device"; then
              # Probeer eerst de standaard partitie node (bv. /dev/loopXp1)
              local partition="${loop_device}p1"
              if [ -b "$partition" ]; then
                  part_mount="/mnt/${base}_p1"
                  echo "[INFO] Partitie $partition gedetecteerd. Creëren van partitie-mount-directory: $part_mount"
                  mkdir -p "$part_mount" || { echo "[ERROR] Kan $part_mount niet aanmaken." >&2; exit 1; }
                  GLOBAL_MOUNT_DIRS+=("$part_mount")
                  echo "[INFO] Mounten van partitie '$partition' als read-only naar '$part_mount'"
                  sudo mount -o ro "$partition" "$part_mount" || { echo "[ERROR] Mounten van $partition mislukt." >&2; exit 1; }
              else
                  # Gebruik kpartx om de partities te mappen
                  local kpartx_mapping
                  kpartx_mapping=$(map_partitions "$loop_device")
                  if [ -n "$kpartx_mapping" ] && [ -b "$kpartx_mapping" ]; then
                      part_mount="/mnt/${base}_p1"
                      echo "[INFO] kpartx mapping gevonden: $kpartx_mapping. Creëren van mount-directory: $part_mount"
                      mkdir -p "$part_mount" || { echo "[ERROR] Kan $part_mount niet aanmaken." >&2; exit 1; }
                      GLOBAL_MOUNT_DIRS+=("$part_mount")
                      echo "[INFO] Mounten van kpartx device '$kpartx_mapping' als read-only naar '$part_mount'"
                      sudo mount -o ro "$kpartx_mapping" "$part_mount" || { echo "[ERROR] Mounten van $kpartx_mapping mislukt." >&2; exit 1; }
                  else
                      echo "[INFO] Geen partitie mapping gevonden, mount het gehele device."
                      part_mount="/mnt/${base}_whole"
                      mkdir -p "$part_mount" || { echo "[ERROR] Kan $part_mount niet aanmaken." >&2; exit 1; }
                      GLOBAL_MOUNT_DIRS+=("$part_mount")
                      echo "[INFO] Mounten van geheel loop device '$loop_device' als read-only naar '$part_mount'"
                      sudo mount -o ro "$loop_device" "$part_mount" || { echo "[ERROR] Mounten van $loop_device mislukt." >&2; exit 1; }
                  fi
              fi
         else
              part_mount="/mnt/${base}_whole"
              echo "[INFO] Geen partition table gedetecteerd op $loop_device. Creëren van mount-directory: $part_mount"
              mkdir -p "$part_mount" || { echo "[ERROR] Kan $part_mount niet aanmaken." >&2; exit 1; }
              GLOBAL_MOUNT_DIRS+=("$part_mount")
              echo "[INFO] Mounten van geheel loop device '$loop_device' als read-only naar '$part_mount'"
              sudo mount -o ro "$loop_device" "$part_mount" || { echo "[ERROR] Mounten van $loop_device mislukt." >&2; exit 1; }
         fi
    fi

    echo "$loop_device"
}

#####################################
# Functie: Assembleer een RAID-array uit meerdere loop devices en mount deze read-only.
#
# Argumenten:
#   $1: RAID mount-directory
#   $2...$n: lijst met loop devices
#####################################
#####################################
# Functie: Assembleer een RAID-array uit meerdere loop devices en mount deze read-only.
#
# Argumenten:
#   $1: RAID mount-directory
#   $2...$n: lijst met loop devices
#####################################
assemble_raid() {
    local raid_mount="$1"
    shift
    local loop_devices=("$@")

    if [ "${#loop_devices[@]}" -lt 2 ]; then
        echo "[ERROR] Minstens twee loop devices zijn vereist voor RAID-assemblering." >&2
        exit 1
    fi

    # Dynamisch de RAID mount-directory aanmaken op basis van de basenamen van de images
    local raid_mount_base="${raid_mount:-"/mnt/raid"}"
    local raid_mount_dir="${raid_mount_base}_$(IFS=_; echo "${BASE_NAMES[*]}")"

    echo "[INFO] Creëren van RAID mount-directory: $raid_mount_dir"
    mkdir -p "$raid_mount_dir" || { echo "[ERROR] Kan $raid_mount_dir niet aanmaken." >&2; exit 1; }
    GLOBAL_MOUNT_DIRS+=("$raid_mount_dir")

    # Assembleren van de RAID-array met mdadm, gebruikt een dynamische naam voor de RAID-device
    local raid_device="${RAID_DEVICE:-/dev/md0}"

    echo "[INFO] Assembleren van RAID-array met mdadm"
    if ! sudo /sbin/mdadm --assemble --run "$raid_device" "${loop_devices[@]}"; then
        echo "[ERROR] RAID-assembleren mislukt bij het uitvoeren van mdadm --assemble." >&2
        RAID_ASSEMBLE_FAILED=true
    else
        echo "[INFO] RAID-array $raid_device succesvol geassembleerd. Huidige status:"
        cat /proc/mdstat || { echo "[ERROR] Kan RAID-status niet uitlezen." >&2; exit 1; }
    fi

    # Probeer de RAID-array opnieuw samen te stellen met --scan, als de eerste poging faalde
    echo "[INFO] Proberen om RAID te assembleren met --scan (ook als de eerste poging mislukt is)"
    if ! sudo /sbin/mdadm --assemble --scan; then
        echo "[ERROR] RAID assembleren via --scan mislukt." >&2
        exit 1
    fi

    # Mounten van de RAID-array naar de dynamisch aangemaakte mount-directory
    echo "[INFO] Mounten van RAID-array $raid_device als read-only naar '$raid_mount_dir'"
    if ! sudo mount -o ro "$raid_device" "$raid_mount_dir"; then
        echo "[ERROR] Mounten van RAID-array mislukt." >&2
        exit 1
    fi

    # Toon waar de array gemount is
    echo "[INFO] RAID-array succesvol gemount op $raid_mount_dir"
}










#####################################
# Parameterverwerking
#####################################
ARGS=()
while [[ "$1" != "" ]]; do
    case "$1" in
        --help|-h)
            usage
            ;;
        --mode)
            shift
            if [[ "$1" != "auto" && "$1" != "raid" && "$1" != "single" ]]; then
                echo "[ERROR] Ongeldige mode: $1. Kies auto, raid of single." >&2
                exit 1
            fi
            MODE="$1"
            ;;
        *)
            ARGS+=("$1")
            ;;
    esac
    shift
done

if [ "${#ARGS[@]}" -lt 1 ]; then
    usage
fi

#####################################
# Automatische modusbepaling
#####################################
if [ "$MODE" = "auto" ]; then
    # Bepaal via eenvoudige naamvergelijking (en eventueel extra metadata) of RAID gewenst is.
    SELECTED_MODE=$(determine_auto_mode "${ARGS[@]}")
    echo "[INFO] Auto mode detectie: geselecteerde modus is '$SELECTED_MODE'."
else
    SELECTED_MODE="$MODE"
    echo "[INFO] Geselecteerde modus via parameter: '$SELECTED_MODE'."
fi

#####################################
# Hoofdverwerking: Mount de images
#####################################
declare -a BASE_NAMES=()
declare -a LOOP_DEVICES=()

for image_file in "${ARGS[@]}"; do
    local_filename=$(basename "$image_file")
    base="${local_filename%.*}"
    BASE_NAMES+=("$base")
    echo "[INFO] Verwerken van bestand: $image_file"
    loop_dev=$(mount_single_image "$image_file")
    LOOP_DEVICES+=("$loop_dev")
done

if [ "$SELECTED_MODE" = "raid" ]; then
    RAID_DIR="/mnt/raid_$(IFS=_; echo "${BASE_NAMES[*]}")"
    echo "[INFO] RAID modus: RAID mount-directory wordt aangemaakt: $RAID_DIR"
    assemble_raid "$RAID_DIR" "${LOOP_DEVICES[@]}"
    echo "[INFO] RAID montage voltooid. De array is gemount op: $RAID_DIR"
else
    echo "[INFO] Single modus: Individuele mount operaties voltooid."
fi

echo "[INFO] Alle operaties succesvol afgerond."
