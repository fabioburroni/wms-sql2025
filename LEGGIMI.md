# Conversione backup SQL Server 2025 → script per SQL Server 2016

Questa cartella avvia un SQL Server 2025 dentro GitHub Codespaces, ripristina il backup
e genera uno script `.sql` (schema + dati) compatibile con SQL Server 2016.

## Istruzioni

1. **Crea un repository privato** su https://github.com/new (es. `sql2025-to-2016`).
2. Nella pagina del repository vuoto, clicca **"uploading an existing file"** e trascina
   **tutto il contenuto** di questa cartella, compresa la cartella `.devcontainer`. Poi clicca **Commit changes**.
3. Clicca **Code → Codespaces → Create codespace on main**. La prima volta servono 2-3 minuti.
4. Quando si apre l'editor nel browser, **trascina il file `.bak`** nel pannello dei file a sinistra.
5. Nel terminale in basso scrivi:
   ```
   bash converti.sh nome_del_tuo_file.bak
   ```
   Lo script ripristina il backup su SQL Server 2025, genera lo script per il 2016 e lo prova
   su SQL Server 2017 in modalità di compatibilità 2016 (livello 130).
6. Nella cartella `output` trovi `NOME_sql2016.sql`: **tasto destro → Download**.
7. Su SQL Server 2016 crea un database vuoto, apri lo script in SSMS ed eseguilo.

## Dopo

- **Elimina il Codespace** da https://github.com/codespaces (menu `...` → Delete): così liberi le ore gratuite
  e non resta nessuna copia del backup.
- Il file `.bak` e la cartella `output` non finiscono mai nel repository (sono esclusi da `.gitignore`).

## Note

- Il backup deve essere un backup **completo** (FULL), non differenziale o di log.
- Se il backup è cifrato (TDE o con certificato), il ripristino non funziona senza il certificato.
- Se lo script segnala costrutti non supportati dal 2016 (tipi `json`/`vector`, collation `_UTF8`,
  `STRING_AGG`…), mandami le righe segnalate oppure `output/verifica.log` e le sistemiamo.
