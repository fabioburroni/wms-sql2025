#!/usr/bin/env bash
# Avvia SQL Server 2025 nel Codespace e (la prima volta) ripristina il backup.
# Il server resta acceso e i dati restano salvati anche se il Codespace viene fermato e riavviato.
#
# Uso:  bash avvia.sh [file.bak] [NomeDatabase] [PasswordSA]
# Esempio:  bash avvia.sh wms.bak
set -euo pipefail

BAK="${1:-wms.bak}"
DB="${2:-wms}"
PASS="${3:-Wms2025!Prova}"
NAME=sql2025
IMAGE=mcr.microsoft.com/mssql/server:2025-latest
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sqlq() {
    docker exec -i "$NAME" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$PASS" -C -b "$@"
}

# 1. Avvio del container (con volume persistente e riavvio automatico)
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "Container già esistente: lo avvio."
    docker start "$NAME" >/dev/null
else
    echo "Creo il container SQL Server 2025 (il primo download richiede 1-2 minuti)..."
    docker run -d --name "$NAME" --restart unless-stopped \
        -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$PASS" \
        -p 1433:1433 \
        -v sql2025data:/var/opt/mssql \
        -v "$SCRIPT_DIR":/backup:ro \
        "$IMAGE" >/dev/null
fi

echo -n "Attendo l'avvio di SQL Server"
for _ in $(seq 1 90); do
    if sqlq -Q "SELECT 1" >/dev/null 2>&1; then echo " pronto."; break; fi
    echo -n "."; sleep 2
done
sqlq -Q "SELECT 1" >/dev/null 2>&1 || { echo; echo "SQL Server non risponde. Log:"; docker logs "$NAME" | tail -30; exit 1; }

# 2. Ripristino (solo se il database non esiste ancora)
EXISTS="$(sqlq -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = N'$DB'")"
if [ "$EXISTS" = "1" ]; then
    echo "Il database [$DB] è già presente: nessun ripristino."
else
    [ -f "$SCRIPT_DIR/$BAK" ] || { echo "Non trovo $BAK nella cartella del progetto: trascinalo nel pannello dei file a sinistra."; exit 1; }
    chmod a+r "$SCRIPT_DIR/$BAK"
    echo "Ripristino $BAK come [$DB]..."
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
    done < <(sqlq -h -1 -W -s '|' -Q "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK = N'/backup/$BAK'" | grep '|')
    [ -n "$MOVES" ] || { echo "Impossibile leggere l'elenco dei file dal backup."; exit 1; }
    sqlq -Q "RESTORE DATABASE [$DB] FROM DISK = N'/backup/$BAK' WITH ${MOVES} RECOVERY, STATS = 25"
fi

echo
echo "Tabelle in [$DB]:"
sqlq -d "$DB" -W -Q "SET NOCOUNT ON; SELECT s.name + '.' + t.name AS tabella, SUM(p.rows) AS righe FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1) GROUP BY s.name, t.name ORDER BY 1"

echo
echo "SQL Server 2025 è acceso nel Codespace."
echo "  Utente: sa     Password: $PASS     Database: $DB"
