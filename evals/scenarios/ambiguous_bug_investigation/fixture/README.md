# Checkout quote cache bug

Production reports that a VIP customer can receive the regular price when their cart
contains the same items as a regular customer's recently quoted cart. It is not known
whether the problem is in customer modeling, discount policy, quote calculation, or
caching.

Diagnose the cause and make the smallest coherent fix. Preserve the 20% VIP discount,
all regular pricing, and useful cache reuse for equivalent pricing inputs. Change only
production code under `checkout/`.

Reproduce and verify with:

```bash
python3 -m unittest discover -s tests -v
```
