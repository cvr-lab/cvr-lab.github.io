---
title: Ego-motion from event-inertial normal flow
authors:
  - Alvaro Novo
  - Cornelia Fermüller
  - Samuel Romero
  - José Manuel Rodríguez Álvarez
  - Francisco Barranco
date: '2026-01-01'
publishDate: '2026-11-23T16:41:56.847508Z'
publication_types:
  - article-journal
publication:
  name: '*Computer Vision and Image Understanding*'
abstract: Event cameras are bio-inspired sensors that respond asynchronously to the scene dynamics with latencies on the order of a few microseconds. These cameras naturally perform smart spatiotemporal gradient compression of the field of view, triggering events (per-pixel brightness changes) and focusing on edges. Compared to optical flow, normal flow is more reliably estimated at strong edges at the boundaries of objects. Thus, event cameras hint at the potential for ego-motion direct estimation from event-based normal flow fields. In this paper, building on the success of a recently developed accurate event-based normal flow prediction algorithm, we propose a direct method for ego-motion estimation, assisted by periodic IMU-based motion priors. Our method optimizes a cost function that combines complementary constraints on event-based normal flow. We perform experiments on real-world scenarios that show competitive performance against state-of-the-art approaches, while ablation studies highlight the complementary contributions of the proposed constraints. The code is available at https://github.com/Novotendo/event_based_normal_flow_egomotion.git
hugoblox:
  ids:
    doi: 10.1016/j.cviu.2026.105008
---
