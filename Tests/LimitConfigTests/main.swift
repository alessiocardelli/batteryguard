// Casi limite della soglia letta dal file di configurazione (scrivibile dall'utente, letto dal servizio root).
// Si compila insieme a LimitConfig.swift con scripts/test.sh: XCTest non c'è nei Command Line Tools.

import Foundation

var failures = 0

func expect(_ text: String, _ expected: Int?, _ line: UInt = #line) {
    let got = LimitConfig.parse(text)
    if got != expected {
        failures += 1
        print("FALLITO riga \(line): parse(\(text.debugDescription)) = \(String(describing: got)), atteso \(String(describing: expected))")
    }
}

// Intervallo valido 50-80, estremi compresi
expect("limit=50\n", 50)
expect("limit=65\n", 65)
expect("limit=80\n", 80)
expect("limit = 75 \n", 75)

// Sotto il minimo o sopra il vecchio massimo: ignorato, il servizio tiene l'ultimo valido
expect("limit=49\n", nil)
expect("limit=0\n", nil)
expect("limit=-80\n", nil)
expect("limit=101\n", nil)
expect("limit=150\n", nil)

// Valori 81-100 scritti dalle prime versioni: diventano 80
expect("limit=81\n", 80)
expect("limit=95\n", 80)
expect("limit=100\n", 80)

// Testo rotto o scrittura a metà
expect("", nil)
expect("limit=\n", nil)
expect("limit=8", nil)
expect("limit=7x\n", nil)
expect("soglia=70\n", nil)
expect("limit=abc\nlimit=70\n", 70)

// Default e intervallo coerenti con l'interfaccia
if LimitConfig.defaultLimit != 80 || LimitConfig.range != 50...80 {
    failures += 1
    print("FALLITO: default \(LimitConfig.defaultLimit), intervallo \(LimitConfig.range)")
}

if failures > 0 {
    print("\(failures) test falliti")
    exit(1)
}
print("LimitConfig: tutti i test passati")
