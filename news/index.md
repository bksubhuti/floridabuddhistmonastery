---
title: "News"
layout: default
permalink: /news/
---

<div class="fla-news">
  {% for post in site.posts %}
  <article class="fla-row">
    <a href="{{ post.url | relative_url }}">
      {% assign thumb = post.header.teaser | default: post.thumbnail | default: post.image %}
      {% if thumb %}
      <div class="fla-thumb">
        <img src="{{ thumb | relative_url }}" alt="{{ post.title }}">
      </div>
      {% endif %}
      <div class="fla-info">
        <h2 class="fla-title">{{ post.title }}</h2>
        <p class="fla-meta">{{ post.date | date: "%b %-d, %Y" }}</p>
        <p class="fla-excerpt">{{ post.excerpt | strip_html | truncate: 180 }}</p>
      </div>
    </a>
  </article>
  {% endfor %}
</div>

<style>
.fla-news {
  max-width: 950px;
  margin: 2rem auto;
  padding: 0 1rem;
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
}
.fla-row {
  display: flex;
  flex-direction: row;
  align-items: flex-start;
  background: #fff;
  border-radius: 12px;
  overflow: hidden;
  box-shadow: 0 2px 10px rgba(0,0,0,.08);
  transition: 0.25s;
}
.fla-row:hover {
  transform: translateY(-3px);
  box-shadow: 0 6px 14px rgba(0,0,0,.15);
}
.fla-row a {
  display: flex;
  flex: 1;
  text-decoration: none;
  color: inherit;
}
.fla-thumb {
  flex: 0 0 260px;
  height: 180px;
  overflow: hidden;
}
.fla-thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  transition: transform .3s ease;
}
.fla-row:hover .fla-thumb img {
  transform: scale(1.05);
}
.fla-info {
  flex: 1;
  padding: 1.1rem 1.25rem;
}
.fla-title {
  font-size: 1.3rem;
  margin: 0 0 .4rem;
  color: #222;
}
.fla-meta
