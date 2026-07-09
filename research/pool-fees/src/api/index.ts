import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { graphql } from "ponder";

// Minimal API — GraphQL over the indexed swap/liquidity tables. The fee
// reconstruction reads the data via this or directly from PGlite (.ponder/).
const app = new Hono();
app.use("/", graphql({ db, schema }));
app.use("/graphql", graphql({ db, schema }));
export default app;
