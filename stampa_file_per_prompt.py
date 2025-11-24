import os
import sys  # Importiamo 'sys' per la redirezione

def esplora_cartella_specifica(directory_partenza):
    """
    Naviga ricorsivamente in UNA directory specifica e stampa il contenuto
    dei file, escludendo file e cartelle nascoste (che iniziano con '.').
    Tutto l'output viene gestito da sys.stdout.
    """

    print(f"\n===== Cartella {directory_partenza} =====")

    base_dir = os.getcwd()  # directory da cui viene eseguito lo script

    for dirpath, dirnames, filenames in os.walk(directory_partenza, topdown=True):

        dirnames[:] = [d for d in dirnames if not d.startswith('.')]

        for filename in filenames:

            if filename.startswith('.'):
                continue

            file_path = os.path.join(dirpath, filename)

            # Calcola path relativo con prefisso "./"
            path_rel = "./" + os.path.relpath(file_path, base_dir)

            try:
                with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                    contenuto = f.read()

                print(f"--- {path_rel} ---")
                print(contenuto)
                print("-" * (len(path_rel) + 8))

            except PermissionError:
                print(f"--- {path_rel} ---")
                print("<Accesso negato (PermissionError)>")
                print("-" * (len(path_rel) + 8))

            except Exception as e:
                print(f"--- {path_rel} ---")
                print(f"<Errore durante la lettura: {e}>")
                print("-" * (len(path_rel) + 8))

    print(f"===== FINE Cartella {directory_partenza} =====")


# --- ESECUZIONE ---

cartelle_da_includere = [
    "Consumer",
    "K8s",
    "Metrics-service",
    "Producer"
]

file_output = "contenuto_prompt_NEW.txt"

stdout_originale = sys.stdout

try:
    with open(file_output, 'w', encoding='utf-8') as f:
        sys.stdout = f
        
        for cartella in cartelle_da_includere:
            if os.path.isdir(cartella):
                esplora_cartella_specifica(cartella)
            else:
                print(f"\n===== ATTENZIONE: La cartella '{cartella}' non è stata trovata. Salto. =====")

except Exception as e:
    sys.stdout = stdout_originale
    print(f"Si è verificato un errore imprevisto: {e}")

finally:
    sys.stdout = stdout_originale

print(f"Fatto! L'output è stato salvato in '{file_output}'.")
