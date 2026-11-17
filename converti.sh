#!/usr/bin/env bash
# Converte un backup SQL Server 2025 (.bak) in uno script .sql eseguibile su SQL Server 2016.
# Uso:  bash converti.sh mio_backup.bak [NomeDatabase]
# Per saltare la verifica finale:  VERIFICA=0 bash converti.sh mio_backup.bak
set -euo pipefail

BAK="${1:?Uso: bash converti.sh file.bak [NomeDatabase]}"
[ -f "$BAK" ] || { echo "File non trovato: $BAK"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAK_DIR="$(cd "$(dirname "$BAK")" && pwd)"
BAK_NAME="$(basename "$BAK")"
DB="${2:-$(basename "$BAK_NAME" .bak | tr -c 'A-Za-z0-9_\n' '_')}"
OUT_DIR="$SCRIPT_DIR/output"
OUT="$OUT_DIR/${DB}_sql2016.sql"
PASS="Conv$(openssl rand -hex 8)!Aa1"
SRC=sql2025
CHK=sql2017check
VERIFICA="${VERIFICA:-1}"

mkdir -p "$OUT_DIR"
chmod a+r "$BAK"
chmod a+rwx "$OUT_DIR"

cleanup() { docker rm -f "$SRC" "$CHK" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Esegue sqlcmd dentro un container (trova da solo il percorso di sqlcmd)
sqlq() {
    local c="$1"; shift
    local bin extra=()
    bin="$(docker exec "$c" bash -c 'ls /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd 2>/dev/null | head -1')"
    [[ "$bin" == *tools18* ]] && extra=(-C)
    docker exec -i "$c" "$bin" -S localhost -U sa -P "$PASS" "${extra[@]}" -b "$@"
}

wait_ready() {
    local c="$1"
    echo -n "Attendo l'avvio di SQL Server ($c)"
    for _ in $(seq 1 90); do
        if sqlq "$c" -Q "SELECT 1" >/dev/null 2>&1; then echo " pronto."; return 0; fi
        echo -n "."; sleep 2
    done
    echo; echo "SQL Server non si è avviato. Log:"; docker logs "$c" | tail -30; exit 1
}

echo "== 1/4  Avvio SQL Server 2025 =="
cleanup
docker run -d --name "$SRC" -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$PASS" \
    -p 1433:1433 -v "$BAK_DIR":/backup:ro \
    mcr.microsoft.com/mssql/server:2025-latest >/dev/null
wait_ready "$SRC"

echo "== 2/4  Ripristino del backup come [$DB] =="
BAK_SQL="${BAK_NAME//\'/\'\'}"
MOVES=""
i=0
while IFS='|' read -r logical _phys type _rest; do
    [ -z "$logical" ] && continue
    i=$((i+1))
    case "$type" in
        L) ext=ldf ;;
        *) ext=mdf; [ $i -gt 1 ] && ext=ndf ;;
    esac
    MOVES+="MOVE N'${logical//\'/\'\'}' TO N'/var/opt/mssql/data/${DB}_${i}.${ext}', "
done < <(sqlq "$SRC" -h -1 -W -s '|' -Q "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK = N'/backup/$BAK_SQL'" | grep '|')
[ -n "$MOVES" ] || { echo "Impossibile leggere l'elenco dei file dal backup."; exit 1; }

sqlq "$SRC" -Q "RESTORE DATABASE [$DB] FROM DISK = N'/backup/$BAK_SQL' WITH ${MOVES} RECOVERY, STATS = 25"

echo "== 3/4  Generazione dello script per SQL Server 2016 =="
pwsh -NoProfile -File "$SCRIPT_DIR/export.ps1" -Database "$DB" -Password "$PASS" -OutFile "$OUT"

# Segnala costrutti che non esistono in SQL Server 2016
echo "-- Controllo costrutti non supportati dal 2016 --"
if iconv -f UTF-16 -t UTF-8 "$OUT" | grep -niE \
    '_UTF8|\bvector\s*\(|\[json\]|STRING_AGG|\bTRIM\s*\(|CONCAT_WS|GREATEST\s*\(|LEAST\s*\(|GENERATE_SERIES|DATE_BUCKET|DATETRUNC|JSON_OBJECT|JSON_ARRAY|LEDGER\s*=|AS (NODE|EDGE)|REGEXP_' \
    | head -20; then
    echo ">> ATTENZIONE: le righe sopra usano funzionalità successive al 2016 e vanno corrette."
else
    echo "Nessun costrutto sospetto trovato."
fi

if [ "$VERIFICA" = "1" ]; then
    echo "== 4/4  Prova di esecuzione su SQL Server 2017 in modalità 2016 (compat. 130) =="
    docker run -d --name "$CHK" -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$PASS" \
        -v "$OUT_DIR":/out:ro mcr.microsoft.com/mssql/server:2017-latest >/dev/null
    wait_ready "$CHK"
    sqlq "$CHK" -Q "CREATE DATABASE [Verifica]; ALTER DATABASE [Verifica] SET COMPATIBILITY_LEVEL = 130;"
    if sqlq "$CHK" -d Verifica -i "/out/$(basename "$OUT")" > "$OUT_DIR/verifica.log" 2>&1; then
        echo "Script eseguito senza errori."
    else
        echo ">> Errori durante la prova (dettagli in output/verifica.log):"
        grep -iE 'Msg|Error' "$OUT_DIR/verifica.log" | head -20 || true
    fi
else
    echo "== 4/4  Verifica saltata =="
fi

echo
echo "FATTO. Script pronto: output/$(basename "$OUT")"
echo "Scaricalo (tasto destro sul file > Download) ed eseguilo in SSMS su un database vuoto del tuo SQL Server 2016."
