# Commercial conclusion

The technical question had a clear answer (it works). The commercial question had one too: it doesn't work as a product, and the reasons are more interesting than the benchmark.

> Not legal advice. The licence readings below come from n8n's own LICENSE.md and support documentation, quoted verbatim. Anyone planning to sell work built this way should confirm their own case with n8n directly.

## 1. The licence decides the shape

n8n is released under the **Sustainable Use License**, not an OSI open-source licence:

> "You may use or modify the software only for **your own internal business purposes** or for non-commercial or personal use."

> "You may distribute the software or provide it to others **only if you do so free of charge for non-commercial purposes**."

And from n8n's support documentation:

> "If your role is limited to assisting your clients with setting up their own internal instances of n8n, **no commercial license would be required on your part**."

> "If you intend to host and manage your clients' workflows and credentials within **your own internal n8n instance**, an Enterprise license would be required."

Mapped onto the ways this could be sold:

| Shape | Status |
|---|---|
| A company runs n8n Community for its own warehouse | ✅ Internal business use |
| A consultant sets up the company's own instance | ✅ Explicitly permitted by n8n |
| The consultant delivers their own schema and workflows onto that instance | ✅ Likely fine: that's the consultant's work, not n8n's software. The one boundary worth confirming in writing. |
| The consultant hosts the WMS for the customer | ⚠️ Needs an Enterprise licence |
| White-labelled so the customer never sees n8n | ⚠️ Needs an Embed licence |
| An appliance or image containing n8n, sold as a product | ❌ Commercial distribution: not permitted |

**A product is ruled out; a service is possible.** As soon as "the WMS" is something you ship rather than something you configure on the customer's own n8n, you are distributing n8n commercially.

Community Edition is technically enough for an SME. Workflows and executions are unlimited, queue mode is included (so the measured ~50 executions/s ceiling is a default, not a hard cap), and warehouse operators never log in to n8n at all. They only hit webhooks from a browser, so Community Edition's lack of user roles never affects them.

## 2. The market already has a free answer

| Option | Self-hosted | Cost | Maturity |
|---|---|---|---|
| **ERPNext** (Stock) | Yes | Free | Mature, multi-warehouse, bin-level, batch/serial, barcode, real community |
| **Odoo** Inventory | Yes (Community) | Paid for the full suite | Mature, barcode, strong reporting |
| **OpenBoxes** | Yes | Free | Established in health and NGO logistics |
| **openWMS.org** | Yes | Free | API-first, for building a custom logistics layer |
| **This project** | Yes | n/a | Two flows, one developer, no community |

ERPNext alone delivers every headline benefit I had listed for this idea: affordable, self-hosted, customisable, no lock-in and barcode-driven, with years of hardening behind it.

The one thing an n8n build genuinely does better is **integration reach**: hundreds of connectors turn a bespoke ERP, carrier or marketplace hook-up into hours of work instead of a custom module. That's a real advantage, but it argues for *n8n next to a real WMS*, not n8n *as* the WMS.

## 3. Why not build an independent WMS instead?

Technology isn't the constraint; the build shows the domain model, the transactional discipline and the operator UX are all achievable. The constraint is the economics of mission-critical, on-premise software sold to small and mid-sized companies:

- **Support is effectively 24/7.** When the WMS is down, the warehouse stops. It's the first question every serious buyer asks, and one person can't credibly answer it.
- **Sales cycles are long.** References, site visits, procurement, security questionnaires and, in Germany, works-council consultation.
- **The integration surface never shrinks.** Every customer has a different ERP, carrier, marketplace, label printer and scanner. This is where WMS projects actually fail.
- **The market is crowded at every tier**, from free (ERPNext, Odoo Community) to enterprise (SAP EWM, Manhattan, Blue Yonder).

The sensible route into software from here is the usual one: do the work as services, notice what gets built every single time, and productise only that. That's a decision to make after several paid implementations, not before the first.

## 4. Where that leaves it

- **As a product:** no. The licence rules it out, and the free incumbents are better.
- **As a service on the customer's own n8n:** permitted and technically sound. The economics depend on reuse across several implementations; one-off, it doesn't beat ordinary consulting.
- **As evidence:** this is what it's actually for. It shows n8n *can* serve fast, correct, stateful UI, where exactly it stops being the right tool, and how to test the difference.

### Sources

- [n8n Sustainable Use License (LICENSE.md)](https://github.com/n8n-io/n8n/blob/master/LICENSE.md)
- [n8n Help Center: which license do I need for my use case?](https://support.n8n.io/article/can-i-use-your-license-for-my-use-case)
- [n8n Embed documentation](https://docs.n8n.io/embed/)
- [ERPNext warehouse management review (ERP Research)](https://www.erpresearch.com/erp/erpnext/warehouse-management)
