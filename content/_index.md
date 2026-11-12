---
title: ''
date: 2026-10-15
type: landing

sections:
  - block: hero
    content:
      title: Computer Vision and Robotics Lab
      text: The Computer Vision and Robotics Laboratory is a research group at the University of Granada dedicated to active vision, real-time processing, neuromorphic engineering, and robotics.
      media:
        src: hero.jpg
      primary_action:
        text: Our projects
        url: projects/
      secondary_action:
        text: Meet the team
        url: people/
    design:
      layout: split-left
      size: compact

  - block: focus-areas
    id: about
    content:
      title: What we research
      text: |-
        We are part of the [Department of Computer Engineering, Automation and Robotics](https://icar.ugr.es/) at the [University of Granada](https://www.ugr.es). Our focus is active vision: sensors that change their point of view, adapt how they perceive their environment, and select the information the task needs, so that robots can make smart decisions in real time.
      items:
        - name: Active vision and robotics
          description: Perception-action loops, attention, and collaboration for robots that look where the task requires.
          icon: hero/eye
          topics: [Attention, Manipulation, Robotics]
        - name: Neuromorphic vision
          description: Event-based cameras for low-latency clustering, tracking, contour detection, and navigation.
          icon: hero/bolt
          topics: [Neuromorphic, Contours, Dataset]
        - name: Real-time architectures
          description: FPGA and edge pipelines that run dense vision at low power and full frame rate.
          icon: hero/clock
          topics: [FPGA, Real-time systems, High performance]
        - name: Autonomous navigation
          description: Egomotion, SLAM, and structure from motion for drones and mobile robots.
          icon: hero/paper-airplane
          topics: [Drones, SLAM, Navigation]
        - name: Motion and low-level vision
          description: Optical flow, stereo, background subtraction, and local contrast descriptors.
          icon: hero/cpu-chip
          topics: [Egomotion, Contours, High performance]
        - name: Applications
          description: Advanced driver assistance (ADAS), video surveillance, and anomaly detection.
          icon: hero/shield-check
          topics: 	[Anomaly, Crowds, Deep Learning]
    design:
      layout: cards

  - block: portfolio
    id: projects
    content:
      title: Projects
      count: 6
      filters:
        folders:
          - projects
      buttons:
        - name: All
          tag: '*'
        - name: Robotics
          tag: Robotics
        - name: Neuromorphic
          tag: Neuromorphic
        - name: Deep Learning
          tag: Deep Learning
        - name: FPGA
          tag: FPGA
        - name: Drones
          tag: Drones
      default_button_index: 0
      archive:
        link: projects/
        text: All projects
    design:
      columns: 3
      fallback_icon: cpu-chip

  - block: collection
    id: news
    content:
      title: Latest News
      count: 3
      filters:
        folders:
          - blog
      order: desc
      archive:
        enable: true
        link: blog/
        text: All news
    design:
      view: date-title-summary
---
