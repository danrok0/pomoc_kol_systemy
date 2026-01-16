# Poradnik i Rozwiązania: Podpowłoki i Potoki Nazwane (IPC) w Bash

## Część 1: Wstęp Teoretyczny

### 1. Podpowłoki (Subshells)
Podpowłoka to osobny proces Bash, który wykonuje polecenie i zwraca jego wynik. Tworzy się ją używając składni `$(komenda)`. Wynik wykonania komendy jest wstawiany w miejsce wywołania.

**Kluczowe cechy:**
* **Izolacja:** Zmienne zmienione w podpowłoce nie zmieniają się w procesie głównym.
* **Zagnieżdżanie:** Można wywoływać podpowłokę w podpowłoce.
* **Przechwytywanie błędów:** Aby złapać błędy, użyj `2>&1`.

### 2. Potoki nazwane (FIFO)
Potok nazwany to specjalny plik umożliwiający komunikację między niezależnymi procesami.
* Tworzenie: `mkfifo /sciezka/do/potoku`
* Działanie: Jeden proces pisze (`>`), drugi czyta (`<`). Procesy **synchronizują się** (czekają na siebie).

---

## Część 2: Rozwiązania Zadań

### Zadanie 1: Proste liczenie plików
Funkcja zlicza pliki w podanym katalogu, używając podpowłoki do przechwycenia wyniku.

```bash
#!/bin/bash

zlicz_pliki() {
    # Walidacja argumentów
    if [ $# -ne 1 ]; then
        echo "Blad: Oczekiwano 1 argumentu" >&2
        return 1
    fi

    katalog="$1"

    if [ ! -d "$katalog" ]; then
        echo "Blad: Katalog nie istnieje" >&2
        return 1
    fi

    # Użycie podpowłoki do pobrania wyniku
    liczba=$(find "$katalog" -maxdepth 1 -type f | wc -l)
    
    echo "Katalog zawiera $liczba plikow"
}

zlicz_pliki "$@"



#!/bin/bash

znajdz_najwieksze() {
    if [ $# -ne 2 ]; then
        echo "Blad: Oczekiwano 2 argumentow (katalog, N)" >&2
        return 1
    fi

    katalog="$1"
    N="$2"

    # Walidacja katalogu i liczby N
    if [ ! -d "$katalog" ]; then
        echo "Blad: Katalog nie istnieje" >&2; return 1
    fi

    if ! [[ "$N" =~ ^[1-9][0-9]*$ ]]; then
        echo "Blad: N musi byc liczba dodatnia" >&2; return 1
    fi

    # Usunięcie końcowego slash'a
    katalog="${katalog%/}"

    liczba_plikow=$(find "$katalog" -maxdepth 1 -type f | wc -l)
    if [ "$liczba_plikow" -eq 0 ]; then
        echo "Katalog jest pusty"; return 0
    fi

    # Obliczanie sumy rozmiarów (użycie paste do złączenia liczb znakiem +)
    total_size=$(find "$katalog" -maxdepth 1 -type f -printf '%s\n' \
                 | paste -sd+ - 2>/dev/null | bc 2>/dev/null)
    
    # Zabezpieczenie przed pustym wynikiem
    if [ -z "$total_size" ] || [ "$total_size" -eq 0 ]; then
        total_size=0
    fi

    # Główna pętla przetwarzania
    find "$katalog" -maxdepth 1 -type f -printf '%s %p\n' \
    | sort -nr \
    | head -n "$N" \
    | while read -r size path; do
        name="${path#$katalog/}"
        # Obliczenia w bc ze skalą i zaokrąglaniem
        procent=$(echo "scale=4; tmp=$size*100/$total_size; \
                  tmp=tmp+0.005; scale=2; tmp" | bc)
        
        echo "$name $size ${procent}%"
    done
}

znajdz_najwieksze "$@"




#!/bin/bash

producer_consumer() {
    if [ $# -ne 2 ]; then
        echo "Uzycie: $0 <iteracje> <okno>" >&2; return 1
    fi

    iteracje="$1"
    okno="$2"
    
    # Tworzenie unikalnego potoku
    fifo="/tmp/pc_fifo_$$"
    mkfifo "$fifo"

    # Definicja producenta
    producer() {
        for ((i=0; i<iteracje; i++)); do
            liczba=$((RANDOM % 101))
            echo "$liczba" > "$fifo"
            sleep 0.1
        done
    }

    # Definicja konsumenta (średnia krocząca)
    consumer() {
        window=()
        while read -r liczba; do
            window+=("$liczba")
            # Przesuwanie okna (usuwanie najstarszego elementu)
            if [ "${#window[@]}" -gt "$okno" ]; then
                window=("${window[@]:1}")
            fi
            
            suma=$(echo "${window[@]}" | tr ' ' '+' | bc)
            srednia=$(echo "scale=2; $suma/${#window[@]}" | bc)
            
            echo "Liczba: $liczba Srednia: $srednia"
        done < "$fifo"
    }

    # Uruchomienie procesów w tle
    producer &
    pid_prod=$!
    
    consumer &
    pid_cons=$!

    # Czekanie na zakończenie i sprzątanie
    wait "$pid_prod"
    wait "$pid_cons"
    rm -f "$fifo"
}

producer_consumer "$@"



#!/bin/bash

bash_python_ipc() {
    plik="$1"
    
    if [ ! -f "$plik" ]; then
        echo "Brak pliku wejsciowego" >&2; return 1
    fi

    fifo_in="/tmp/fifo_in_$$"
    fifo_out="/tmp/fifo_out_$$"
    mkfifo "$fifo_in" "$fifo_out"

    # Uruchomienie Pythona w tle
    # flush=True jest kluczowe dla natychmiastowego wysyłania danych
    python3 - << 'EOF' < "$fifo_in" > "$fifo_out" &
import sys

total_words = 0
total_chars = 0

while True:
    line = sys.stdin.readline().strip()
    if line == 'EOF':
        print(f'DONE {total_words} {total_chars}', flush=True)
        break
    
    words = len(line.split())
    chars = len(line)
    total_words += words
    total_chars += chars
    
    print(f'{words} {chars}', flush=True)
EOF
    pid_py=$!

    # Otwarcie deskryptorów plików (FD 3 do zapisu, FD 4 do odczytu)
    exec 3> "$fifo_in"
    exec 4< "$fifo_out"

    lineno=0
    
    # Pętla czytająca plik w Bashu i wysyłająca do Pythona
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        echo "$line" >&3              # Wyślij do Pythona
        read -r words chars <&4       # Odbierz od Pythona
        echo "Linia $lineno: ${words} slow, ${chars} znakow"
    done < "$plik"

    # Zamknięcie protokołu
    echo "EOF" >&3
    read -r done_tag w_sum c_sum <&4

    if [ "$done_tag" = "DONE" ]; then
        echo "Podsumowanie: ${w_sum} slow, ${c_sum} znakow"
    fi

    # Sprzątanie
    exec 3>&-
    exec 4<&-
    wait "$pid_py" 2>/dev/null
    rm -f "$fifo_in" "$fifo_out"
}




#!/bin/bash

zadanie5() {
    liczba_zadan="$1"
    liczba_workerow="$2"
    
    # (Walidacja argumentów pominięta dla czytelności - patrz oryginał)
    
    start_time=$(date +%s.%N)

    # 1. Kompilacja producenta w C "w locie"
    cat > producer.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(int argc, char *argv[]) {
    if (argc != 2) return 1;
    int n = atoi(argv[1]);
    srand(time(NULL));
    for (int i = 0; i < n; i++) {
        printf("%d\n", 100 + rand() % 901);
        fflush(stdout);
    }
    return 0;
}
EOF
    gcc producer.c -o producer 2>/dev/null

    # 2. Tworzenie potoków
    fifo_tasks="/tmp/fifo_tasks_$$"
    mkfifo "$fifo_tasks"

    for ((i=0; i<liczba_workerow; i++)); do
        mkfifo "/tmp/fifo_w${i}_$$" # Write (do workera)
        mkfifo "/tmp/fifo_r${i}_$$" # Read (od workera)
    done

    # 3. Definicja Workera (Python)
    cat > worker.py <<'EOF'
import sys
def is_prime(n):
    if n < 2: return False
    for i in range(2, int(n**0.5) + 1):
        if n % i == 0: return False
    return True

worker_id = int(sys.argv[1])
while True:
    line = sys.stdin.readline().strip()
    if not line or line == '-1': break
    
    num = int(line)
    res = 'TAK' if is_prime(num) else 'NIE'
    print(f'{num} {res} {worker_id}', flush=True)
EOF

    # 4. Uruchomienie Workerów
    for ((i=0; i<liczba_workerow; i++)); do
        python3 worker.py "$i" <"/tmp/fifo_w${i}_$$" \
                               >"/tmp/fifo_r${i}_$$" &
    done

    # 5. Uruchomienie Producenta
    ./producer "$liczba_zadan" > "$fifo_tasks" &

    # 6. Koordynator (Round-Robin)
    worker_index=0
    
    # Otwarcie deskryptorów dla każdego workera
    exec 3<"$fifo_tasks"
    for ((i=0; i<liczba_workerow; i++)); do
        exec $((10+i))<"/tmp/fifo_r${i}_$$"
        exec $((20+i))>"/tmp/fifo_w${i}_$$"
    done

    while read -r number <&3; do
        current_worker=$worker_index
        # Wyślij zadanie do wybranego workera
        echo "$number" >&$((20+current_worker))
        
        # Odbierz wynik
        read -r num result wid <&$((10+current_worker))
        echo "Zadanie $num: wynik $result (worker $wid)"
        
        # Zmień workera (karuzela)
        ((worker_index=(worker_index+1)%liczba_workerow))
    done

    # Sygnał zakończenia dla workerów
    for ((i=0; i<liczba_workerow; i++)); do
        echo "-1" >&$((20+i))
    done

    # Sprzątanie
    rm -f "$fifo_tasks" /tmp/fifo_w*_"$$" /tmp/fifo_r*_"$$" \
          producer.c producer worker.py
}


















