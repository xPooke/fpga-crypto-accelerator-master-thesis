# ec_ladder.py — EC operations over GF(2^m), the golden model for the ECDH
# accelerator. Field arithmetic is imported from gf2m.py; the LD and x-only
# ladder formulas are the ones the thesis derives for the NIST B-curves.

from gf2m import gf_add, gf_mul, gf_sqr, gf_inv, M_TEST, F_TEST, M_B571, F_B571


def aff2ld(x, y):                 # affine -> LD, trivially (x, y, 1)
      return (x, y, 1)


def ld2aff(X, Y, Z, m, f):        # LD -> affine: x=X/Z, y=Y/Z^2  (the ONLY inversion)
    zi = gf_inv(Z,m,f)
    zi_sqr = gf_sqr(zi,m,f)
    x = gf_mul(X,zi,m,f)
    y = gf_mul(Y,zi_sqr,m,f)
    return (x,y)


def point_double_ld(X1, Y1, Z1, a, b, m, f):   # 2P in LD, no inversion
    X1_sqr = gf_sqr(X1,m,f)
    Z1_sqr = gf_sqr(Z1,m,f)
    Z3 = gf_mul(X1_sqr,Z1_sqr,m,f)               # Z3 = X1^2 * Z1^2
    Z1_quad = gf_sqr(Z1_sqr,m,f)                 # (Z1^2)^2 = Z1^4, one squaring
    X1_quad = gf_sqr(X1_sqr,m,f)                 # X1^4
    T = gf_mul(b,Z1_quad,m,f)                     # T = b*Z1^4
    X3 = gf_add(X1_quad,T)                        # X3 = X1^4 + T
    # Y3 = T*Z3 + X3*(a*Z3 + Y1^2 + T)
    tmp = gf_add(gf_add(gf_mul(a,Z3,m,f),gf_sqr(Y1,m,f)),T)   # a*Z3 + Y1^2 + T
    Y3 = gf_add(gf_mul(T,Z3,m,f), gf_mul(X3,tmp,m,f))         # T*Z3 + X3*tmp
    return (X3,Y3,Z3)


def point_madd_ld(X1, Y1, Z1, x2, y2, a, b, m, f):  # P(LD) + Q(affine), no inversion

    x1,y1 = ld2aff(X1,Y1,Z1,m,f)
    if x1 == x2 and (y1 == y2 or y1 == (x2 ^ y2)):   # also catches P = -Q
        print("ERROR, Points are the same (P = +-Q). It is not allowed!")
        return (0,0,0)

    A = gf_add(gf_mul(y2,gf_sqr(Z1,m,f),m,f),Y1)             # A = y2*Z1^2 + Y1
    B = gf_add(gf_mul(x2,Z1,m,f),X1)                         # B = x2*Z1 + X1
    C = gf_mul(Z1,B,m,f)                                     # C = Z1*B
    D = gf_sqr(B,m,f)
    tmp = gf_mul(a,(gf_sqr(Z1,m,f)),m,f)
    D = gf_mul(D,gf_add(C,tmp),m,f)                          # D = B^2*(C + a*Z1^2)
    Z3 = gf_sqr(C,m,f)                                       # Z3 = C^2
    E  = gf_mul(A,C,m,f)                                     # E = A*C
    X3 = gf_add(gf_add(gf_sqr(A,m,f),D),E)                   # X3 = A^2 + D + E
    F = gf_add(X3,gf_mul(x2,Z3,m,f))                         # F = X3 + x2*Z3
    G = gf_mul(gf_add(x2,y2),gf_sqr(Z3,m,f),m,f)             # G = (x2+y2)*Z3^2
    Y3 = gf_add(gf_mul(gf_add(E,Z3),F,m,f),G)               # Y3 = (E+Z3)*F + G
    return (X3,Y3,Z3)


def mdouble(X,Z,b,m,f):
    '''
    x-only doubling (X,Z) -> 2 * (X,Z), no Y:
    X_new = X^4 + b*Z^4
    Z_new = X^2 * Z^2
    '''
    X_sqr = gf_sqr(X,m,f)                                                # X^2
    Z_sqr = gf_sqr(Z,m,f)                                                # Z^2
    Z_new = gf_mul(X_sqr,Z_sqr,m,f)                                      # Znew = X^2 * Z^2
    X_new = gf_add(gf_sqr(X_sqr,m,f),gf_mul(b,gf_sqr(Z_sqr,m,f),m,f))    # Xnew = X^4 + b*Z^4
    return X_new,Z_new


def madd(X1,Z1,X2,Z2,x,m,f):
    '''
    x-only differential addition P1+P2, with difference = base point x:
    T1 = X1*Z2 ; T2 = X2*Z1
    Z_new = (T1+T2)^2
    X_new = x * Z_new + T1*T2
    '''
    T1 = gf_mul(X1,Z2,m,f)
    T2 = gf_mul(X2,Z1,m,f)
    Z_new = gf_sqr(gf_add(T1,T2),m,f)
    X_new = gf_add(gf_mul(x,Z_new,m,f),gf_mul(T1,T2,m,f))

    return X_new, Z_new


def scalar_mult(k,x,y,a,b,m,f):
    '''
    Montgomery ladder, x-only. Returns (X1,Z1,X2,Z2); x(k*P) = X1/Z1.
    y and a are unused inside the ladder itself — y stays in the signature
    so the call carries everything Mxy (y-recovery) needs afterwards.
    '''
    # init: P1 = P, P2 = 2P
    X1, Z1 = x, 1
    X2, Z2 = mdouble(x,1,b,m,f)  # P2 = 2P computed from P in LD form (x, Z=1)

    # bits of k after the MSB, MSB -> LSB
    for ki in bin(k)[3:]:      # '0'/'1' characters
        if ki == '1':
            X1, Z1 = madd(X1,Z1,X2,Z2,x,m,f)
            X2, Z2 = mdouble(X2,Z2,b,m,f)
        else:
            X2, Z2 = madd(X2,Z2,X1,Z1,x,m,f)
            X1, Z1 = mdouble(X1,Z1,b,m,f)

    return (X1,Z1,X2,Z2)


def Mxy(X1, Z1, X2, Z2, x, y, m, f):
    '''
    y recovery from the ladder output (X1,Z1,X2,Z2) and the base point (x,y):
    builds the true affine point (x1,y1) = k*P.

    Preconditions: x != 0, Z1 != 0 and Z2 != 0.
    '''

    Z1_inv = gf_inv(Z1,m,f)
    Z2_inv = gf_inv(Z2,m,f)

    x1 = gf_mul(X1,Z1_inv,m,f)
    x2 = gf_mul(X2,Z2_inv,m,f)

    # y1 = (x1 + x)·[ (x1 + x)(x2 + x) + x² + y ]·x⁻¹ + y
    step1 = gf_add(x1,x)                                # (x1 + x)
    step2 = gf_mul(step1,gf_add(x2,x),m,f)              # (x1 + x)(x2 + x)
    step3 = gf_add(gf_add(step2,gf_sqr(x,m,f)),y)       # [ (x1 + x)(x2 + x) + x² + y ]
    x_inv = gf_inv(x,m,f)
    step4 = gf_mul(gf_mul(step1,step3,m,f),x_inv,m,f)   # (x1 + x)·[ (x1 + x)(x2 + x) + x² + y ]·x⁻¹
    y1 = gf_add(step4,y)                                # y1

    return (x1,y1)


def cswap(a, b, bit, m):
    '''
    Constant-time conditional swap of two field elements.
    bit=1 -> swap (a,b);  bit=0 -> leave untouched.
    No branching (mask + XOR) -> no if in hardware, so the flow does not
    depend on the bit (resistance to timing/SPA side channels).
    '''
    mask = ((1 << m) - 1) if bit else 0      # all ones (m bits) or all zeros
    t = mask & (a ^ b)
    return a ^ t, b ^ t


def scalar_mult_ct(k, x, y, a, b, m, f):
    '''
    Montgomery ladder, CONSTANT-TIME variant (cswap instead of if/else).
    Same result as scalar_mult, but the flow is IDENTICAL for every bit ->
    resistant to timing/SPA attacks. Returns (X1,Z1,X2,Z2).

    Per-bit pattern:  cswap -> FIXED step (P2=P1+P2 ; P1=2*P1) -> cswap back.
    '''
    X1, Z1 = x, 1
    X2, Z2 = mdouble(x, 1, b, m, f)          # P1=P, P2=2P
    for ki in bin(k)[3:]:
        bit = int(ki)
        # 1) conditionally swap P1 <-> P2 based on the bit
        X1, X2 = cswap(X1, X2, bit, m)
        Z1, Z2 = cswap(Z1, Z2, bit, m)
        # 2) FIXED step (always the same):  P2 = P1 + P2 ;  P1 = 2*P1
        nX2, nZ2 = madd(X2, Z2, X1, Z1, x, m, f)
        nX1, nZ1 = mdouble(X1, Z1, b, m, f)
        X1, Z1, X2, Z2 = nX1, nZ1, nX2, nZ2
        # 3) swap back
        X1, X2 = cswap(X1, X2, bit, m)
        Z1, Z2 = cswap(Z1, Z2, bit, m)
    return (X1, Z1, X2, Z2)


if __name__ == "__main__":
    # quick self-checks (GF(2^4), curve y^2+xy = x^3+x^2+1: a=1, b=1, G=(8,2))
    assert cswap(0xa, 0x5, 1, 4) == (0x5, 0xa)
    assert cswap(0xa, 0x5, 0, 4) == (0xa, 0x5)
    for k in range(1, 16):
        assert scalar_mult_ct(k, 0x8, 0x2, 1, 1, 4, F_TEST) == scalar_mult(k, 0x8, 0x2, 1, 1, 4, F_TEST)
    print("cswap + scalar_mult_ct OK")
