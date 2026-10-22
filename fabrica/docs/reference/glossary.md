---
title: "Glossary — acronyms y términos del dominio Academia Ejemplo 2.0"
created: 2026-05-06
updated: 2026-05-11
author: blackvamp
status: active
---

# Glossary — acronyms y términos del dominio Academia Ejemplo 2.0

Definiciones centralizadas de acronyms y términos usados a través
de los docs del repositorio. Si un término aparece en un doc pero
no aquí, abrir PR para añadirlo.

## §Compliance

- **AEPD** — Agencia Española de Protección de Datos. Autoridad de
  control RGPD en España. Recibe breach notifications Art. 33
  **exclusivamente** vía Sede Electrónica con formulario específico
  de "Notificación de brechas de datos personales (art. 33 RGPD)".
  El email NO es canal formal válido para Art. 33 (la AEPD lo
  exige electrónico vía Sede).
- **AI Act EU** — Reglamento (UE) 2024/1689 sobre inteligencia
  artificial. Academia Ejemplo 2.0 califica como **high-risk system**
  bajo Annex III §3 (educación / evaluación académica).
- **Annex III** — Listado de sistemas AI high-risk según AI Act.
  Punto 3 cubre educación: assessment + admission + monitoring +
  detección de fraude.
- **DPA (Data Processing Agreement)** — Contrato que regula el
  tratamiento de datos personales entre responsable (Talent Network)
  y encargado (vendor: Anthropic, OpenAI, Google, Resend, etc.).
  Obligatorio bajo RGPD Art. 28.
- **DPO (Data Protection Officer)** — Delegado de Protección de
  Datos. Rol obligatorio para tratamientos a gran escala de datos
  especiales (RGPD Art. 37).
- **FUNDAE** — Fundación Estatal para la Formación en el Empleo.
  Gestiona la formación bonificada para empresas en España bajo el
  **Real Decreto 694/2017**. Obligación crítica: retención
  documental 4 años desde la fecha del último curso.
- **RGPD / GDPR** — Reglamento General de Protección de Datos
  (UE 2016/679). Art. 17 (right to erasure), Art. 33 (breach
  notification 72h), Art. 34 (user notification high-risk),
  Art. 6.1.f (legítimo interés), Art. 5.1.c (minimización).

## §Crypto y security

- **AES-256-GCM** — Advanced Encryption Standard, modo Galois
  Counter Mode, 256-bit key. Cifrado autenticado con tag AEAD usado
  en 3 tablas (`dm_messages.body_encrypted`,
  `external_community_links.invite_url_encrypted`,
  `profiles.identity_doc_encrypted`).
- **HKDF** — HMAC-based Key Derivation Function (RFC 5869). Deriva
  keys per-record desde la master key + salt para evitar key reuse.
- **KMS (Key Management Service)** — Sistema centralizado de
  custodia de claves de cifrado. Academia Ejemplo v0 usa **Supabase
  secrets indefinido** (ADR-0015), sin migration a AWS KMS / Vault.
- **PITR (Point-In-Time Recovery)** — Capacidad de restaurar la
  base de datos a cualquier instante dentro de la ventana de
  retención. Supabase Pro+ ofrece PITR de 7 días (ADR-0017).
- **RPO (Recovery Point Objective)** — Máxima cantidad de datos
  aceptable perder en un incidente. Academia Ejemplo v0 RPO = 1 min
  via PITR + 24h via pg_dump R2.
- **RTO (Recovery Time Objective)** — Máximo tiempo aceptable de
  downtime para restore. Academia Ejemplo v0 RTO = 4h.
- **MFA (Multi-Factor Authentication)** — Autenticación con 2+
  factores. Su presencia y enforcement dependen de la política del
  tenant/usuario; v0 delega autenticación en Google OAuth pero NO
  asume que el provider impone MFA (puede estar opt-in según la
  cuenta del usuario). El onboarding y la auditoría compliance
  deben verificar MFA enforcement explícitamente cuando el riesgo
  lo requiera.
- **JWT (JSON Web Token)** — Token firmado para autenticación
  cliente-servidor. Supabase Auth usa JWT con RS256 (asymmetric
  default desde 2025).
- **JWKS (JSON Web Key Set)** — Set de public keys publicadas para
  verificar JWT signatures. Supabase expone JWKS en
  `/auth/v1/.well-known/jwks.json`.
- **RS256** — RSA Signature with SHA-256. Algorithm asymmetric usado
  por Supabase Auth para JWT signing.
- **MADR 4.0** — Markdown Architecture Decision Records v4.0.
  Formato inmutable para ADRs (status + context + decision +
  consequences). Academia Ejemplo 2.0 usa MADR 4.0 en
  `docs/decisions/`.

## §Tech stack

- **Server Component** — React component que se renderiza en el
  servidor (default en Next.js 16 App Router). Sin estado cliente,
  sin event handlers. Marca `"use client"` solo cuando se necesita
  interacción.
- **RLS (Row Level Security)** — Postgres feature que filtra rows
  según el role del caller. Academia Ejemplo enforce RLS en TODAS las
  tablas (regla absoluta 19).
- **RPC (Remote Procedure Call)** — Postgres function callable desde
  PostgREST API. Academia Ejemplo usa RPCs canónicos con `SECURITY
  DEFINER` para operaciones críticas (e.g. `session_block_for_student`).
- **Edge Function** — Función serverless en Supabase Edge Runtime
  (compatible con Deno, V8 isolates), distribuida globalmente en la
  red de centros de datos gestionada por Supabase. Academia Ejemplo
  usa Edge Functions para decrypt helpers, RAG indexing, batch
  nocturno cheating detection.
- **Realtime** — Servicio Supabase para WebSocket subscriptions
  (Broadcast + Presence + Postgres Changes). Academia Ejemplo usa para
  questions live + telemetría del portal + foro (posts/comentarios) + feed
  de ventas de launches + puntos de gamificación + inbox de closers
  WhatsApp.
- **Storage** — Servicio Supabase para archivos (metadata en
  `storage.objects`, files en S3-compatible). Academia Ejemplo usa
  para session recordings + identity docs + content material.
- **pgvector** — Extensión Postgres para vector similarity search
  (HNSW + IVFFlat). Academia Ejemplo usa pgvector con embeddings
  1536-dim para RAG + cheating detection (ADR-0010).
- **Embeddings** — Vector representations de texto generadas por
  modelos LLM (e.g. OpenAI `text-embedding-3-small` + Google
  `gemini-embedding`).

## §Dominio Academia Ejemplo 2.0

- **Talent Brain Match** — Sistema cross-academia para matching de
  alumnos por intereses y goals (F2 §6.4).
- **Cohort Space** — Espacio compartido por todos los alumnos de
  un mismo programa+cohort. Persistente durante el programa
  completo.
- **Talent Circles** — Sub-grupos intra-cohort de 15 días con muro
  grupal propio. Mecánica obligatoria de gamification (regla
  absoluta TA 2.0: imposible Level 7+ sin puntos de Circle).
- **Talentoso (oficial)** — Chatbot tutor IA del programa. Multi-
  vendor configurable (Anthropic / OpenAI / Google) per ADR-0011.
  Routing simétrico con fallback chain.
- **Plaza por programa** — Hub social a nivel programa (vs cohort).
  Persistente más allá del cohort original.
- **Mastery score** — Score agregado de competencia por sub-area
  formativa, calculado desde `progress_events` (correctness, speed,
  recovery, recency). Evidencia FUNDAE.
- **Enrollment source** — Origen del enrollment de un alumno en un
  programa. Enum: `purchased`, `gifted_temporary`,
  `gifted_permanent`, `free_open`, `scholarship`.

## §Phases (proyecto roadmap)

- **F1**: scaffolding inicial (Next.js + Supabase + i18n + tema).
- **F2**: vision academia top 2026 (sintesis cierre).
- **F3**: modelo de datos target (62+ tablas con RLS).
- **F4**: ADRs prioritarios + amendments + runbooks compliance.
- **F5**: runbooks operacionales (incident, KMS compromise,
  Talentoso, dispute, cheating, leakage).
- **F6**: sellado parcial ADRs + sealing playbook.
- **F-cierre**: este PR — gaps documentales internos.
- **F7**: SQL migrations (11 archivos) + amendments aditivos.
- **F8**: UI/API layer + tests + integrations Sentry/Better Stack.
