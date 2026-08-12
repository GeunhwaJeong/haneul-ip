# Haneul IP

An on-chain registry, licensing, and royalty settlement package for creative work, written in Move for the [Haneul](https://github.com/GeunhwaJeong/haneul) network.

> **Status: early development. Unaudited. Not deployed.**
> Interfaces, semantics, and storage layouts may change without notice. Do not build production systems on this code, and do not deploy it to any network that holds real value. A full third-party security audit is a hard requirement before any mainnet deployment.

## Why this exists

Haneul's long-term bet is that a chain earns its place when real money moves across it. Creative industries move a lot of money through opaque pipes: licensing deals are paper contracts, derivative rights are tribal knowledge, and royalty settlement is a spreadsheet someone runs at the end of the quarter.

This package puts the two things a chain is actually good at on-chain, and deliberately leaves everything else off:

- **Rights as data.** Who registered a work, when, under what license terms, and which works derive from which. The derivation graph is fixed at registration time and cannot be rewritten afterwards.
- **Money as code.** When revenue reaches a work, every ancestor in its derivation graph accrues its agreed share in the same instruction. No settlement runs, no trust in an intermediary's arithmetic.

Content itself stays off-chain. This package stores a 32-byte content hash and a URI, nothing more.

## What it does not do

Registration is self-attested: the chain records who claimed what and when, and it cannot verify the claim itself. The dispute module exists to make false claims expensive, not impossible. This package is also not copy protection of any kind. It makes rights machine-readable and settlement automatic; enforcement against off-chain infringement remains an off-chain problem.

## Modules

| Module | Responsibility |
|---|---|
| `ip` | The IP asset object: identity, provenance graph, and revenue vault in one shared object, plus the owner capability and per-asset licensing overrides |
| `terms` | Immutable, machine-readable license terms; internally inconsistent term combinations are rejected at registration |
| `license` | The license object a work sells; non-transferable licenses are enforced by the type system rather than by a transfer hook |
| `derivative` | Derivative registration as a hot-potato builder: begin, add each parent, finish; the ancestor royalty map is merged once at registration |
| `royalty` | Payments in, claims out; ancestor shares accrue per payment and are pulled with the ancestor's own capability |
| `dispute` | Raise, judge, resolve; an upheld dispute freezes the target's licensing and money paths, and propagates down the derivative tree |
| `protocol` | Shared levers: a circuit breaker over every money path and a protocol fee hook (rate starts at zero) |

## Design notes

- **Append-only graph.** A derivative's parents are fixed the moment it is registered. That single property is what allows each asset to carry its full ancestor royalty table as plain object fields, merged once, valid forever.
- **Absolute royalty shares.** An ancestor's share applies to every payment made to a descendant, at the percentage agreed when the link was created. Shares reached through multiple paths accumulate, and the combined burden can never exceed 100%.
- **Slippage guards.** Minting and registration take caller-side limits (`max_fee`, `max_total_stack_bps`), because a licensor can change fees and shares between a buyer signing and the transaction executing.
- **Mint-time snapshots.** A sold license keeps the terms it was sold under; later changes by the licensor apply only to future sales.

## Building and testing

Requires the `haneul` CLI built from the [Haneul repository](https://github.com/GeunhwaJeong/haneul).

```bash
haneul move build
haneul move test
```

The test suite currently covers 90 cases, 57 of which assert failure paths (wrong capabilities, exceeded limits, frozen assets, replayed evidence, and similar).

## Security

This code has not been audited. If you find a vulnerability, please use GitHub's private vulnerability reporting on this repository rather than a public issue.

## License

Apache-2.0
