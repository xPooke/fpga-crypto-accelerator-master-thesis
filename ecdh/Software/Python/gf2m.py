# gf2m.py — aritmetika polja GF(2^m), zlatni model za ECDH akcelerator
# Autor: Marko (ECDH_vezbanje.ipynb, lekcija 2); test: test_gf2m.py
#
# Element polja = polinom stepena < m sa koeficijentima iz {0,1},
# zapisan kao Python int (bit i = koeficijent uz x^i).


def gf_add(a, b):
    return a ^ b


def gf_mul(a: int, b: int, m: int, f: int):
    '''
    a,b - Ulazni podaci
    m   - Stepen prosirenja polja
    f   - nesvodjljivi polinom (SA vodecim bitom x^m, npr. 0b10011 za GF(2^4))
    '''
    acc = 0
    for i in range(m-1, -1, -1):
        acc = acc << 1

        if (acc >> m):          # reduction needed?
            acc ^= f            # reduction

        if ((a >> i) & 1):      # if a[i] = 1
            acc ^= b

    return acc


def gf_sqr(a: int, m: int, f: int):
    '''Kvadriranje: razmicanje (bit i -> 2i) pa redukcija odozgo. Kombinaciono u HW.'''
    s = 0
    for i in range(m):
        if (a >> i) & 1:
            s |= (1 << (2 * i))
    for i in range(2 * m - 2, m - 1, -1):
        if (s >> i) & 1:
            s ^= f << (i - m)
    return s


def gf_inv(a: int, m: int, f: int):
    '''Inverz a^-1 u GF(2^m), Itoh-Tsujii (binarni metod). a != 0.'''
    n = m - 1
    beta = a                                    # MSB: t = 1
    t = 1
    for i in range(n.bit_length() - 2, -1, -1):  # bitovi n=m-1 ISPOD MSB-a
        saved = beta                             # udvoj (t -> 2t), mnozi sa saved
        for _ in range(t):
            beta = gf_sqr(beta, m, f)
        beta = gf_mul(beta, saved, m, f)
        t = 2 * t
        if (n >> i) & 1:                         # "+1" (t -> t+1), mnozi sa a
            beta = gf_sqr(beta, m, f)
            beta = gf_mul(beta, a, m, f)
            t += 1
    return gf_sqr(beta, m, f)                    # finale: jedno kvadriranje


# Vezbovno polje iz lekcija 1-2
M_TEST = 4
F_TEST = 0b10011                                            # x^4 + x + 1

# NIST B-571 (pentanom)
M_B571 = 571
F_B571 = (1 << 571) | (1 << 10) | (1 << 5) | (1 << 2) | 1   # x^571+x^10+x^5+x^2+1


if __name__ == "__main__":
    print(f"A+B  = {gf_add(0b1011, 0b1101):04b}  (papir: 0110)")
    print(f"A*B  = {gf_mul(0b1011, 0b1101, M_TEST, F_TEST):04b}  (papir: 0110)")
    print(f"x*1  = {gf_mul(0b0010, 1, M_TEST, F_TEST):04b}  (mora: 0010)")
