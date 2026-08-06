# Centralize Alert transitions in AlertEngine

One deep `AlertEngine` Module owns ordered Rule evaluation, Monitoring Pause, Collection Window timing, overflow accounting, Acknowledgement, recovery, and every durable Alert transition behind a small ingestion/state Interface. Source runtimes and Toast presentation remain Adapters at its edges, while production and in-memory `AlertStore` Adapters occupy the persistence seam; this avoids split ownership and race-prone choreography across shallow coordinator modules at the cost of concentrating core domain behavior in one actor.
