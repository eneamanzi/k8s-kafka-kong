#Mettere questo file nella root del progetto
#successivamente esegurie con 'python3 stampa_file_per_prompt.py'
#metterà tutto il contenuto importante in un file txt pronto per poterlo usare come prompt



import os
import sys  # Importiamo 'sys' per la redirezione

def esplora_cartella_specifica(directory_partenza):
    """
    Naviga ricorsivamente in UNA directory specifica e stampa il contenuto
    dei file, escludendo file e cartelle nascosti (che iniziano con '.').
    Tutto l'output viene gestito da sys.stdout.
    """
    
    print(f"\n===== Cartella {directory_partenza} =====")
    
    # os.walk() parte dalla directory corrente
    for dirpath, dirnames, filenames in os.walk(directory_partenza, topdown=True):
        
        # Filtra le cartelle nascoste
        dirnames[:] = [d for d in dirnames if not d.startswith('.')]
        
        # Filtra i file
        for filename in filenames:
            
            # Salta i file nascosti
            if filename.startswith('.'):
                continue
            
            file_path = os.path.join(dirpath, filename)
            contenuto = ""
            
            try:
                with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                    contenuto = f.read()
                    
                print(f"--- {filename} ---")
                print(contenuto)
                print("-" * (len(filename) + 8)) # Separatore
                
            except PermissionError:
                print(f"--- {filename} ---")
                print("<Accesso negato (PermissionError)>")
                print("-" * (len(filename) + 8))
                
            except Exception as e:
                print(f"--- {filename} ---")
                print(f"<Errore durante la lettura: {e}>")
                print("-" * (len(filename) + 8))

    print(f"===== FINE Cartella {directory_partenza} =====")

# --- ESECUZIONE ---

# 1. Lista delle SOLE cartelle da analizzare
#    Si aspetta che siano sottocartelle della directory
#    in cui si trova questo script.
cartelle_da_includere = [
    "Consumer",
    "K8s",
    "Metrics-service",
    "Producer"
]

# 2. Nome del file di output
file_output = "contenuto_prompt.txt"

# 3. Salva lo standard output originale (il terminale)
stdout_originale = sys.stdout

try:
    # 4. Apri il file di output e redirigi stdout
    #    'w' significa 'write' (sovrascrive il file se esiste)
    with open(file_output, 'w', encoding='utf-8') as f:
        sys.stdout = f  # Da qui in poi, 'print' scrive sul file 'f'
        
        # 5. Esegui il loop
        for cartella in cartelle_da_includere:
            if os.path.isdir(cartella):
                # Chiama la funzione (il suo output 'print' andrà nel file)
                esplora_cartella_specifica(cartella)
            else:
                print(f"\n===== ATTENZIONE: La cartella '{cartella}' non è stata trovata. Salto. =====")

except Exception as e:
    # Se c'è un errore, stampalo sul terminale originale
    sys.stdout = stdout_originale
    print(f"Si è verificato un errore imprevisto: {e}")

finally:
    # 6. Ripristina sempre lo standard output
    #    Questo fa sì che l'ultimo 'print' vada al terminale
    sys.stdout = stdout_originale

print(f"Fatto! L'output è stato salvato in '{file_output}'.")
