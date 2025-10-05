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
  align-items: stretch;
  background: #fff;
  border-radius: 12px;
  overflow: hidden;
  box-shadow: 0 2px 10px rgba(0,0,0,0.08);
  transition: all 0.25s ease;
}

.fla-row:hover {
  transform: translateY(-3px);
  box-shadow: 0 6px 14px rgba(0,0,0,0.15);
}

.fla-row a {
  display: flex;
  flex: 1;
  flex-direction: row;
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
  display: flex;
  flex-direction: column;
  justify-content: center;
}

.fla-title {
  font-size: 1.3rem;
  margin: 0 0 .4rem;
  color: #222;
  font-weight: 600;
}

.fla-meta {
  color: #777;
  font-size: 0.9rem;
  margin-bottom: .6rem;
}

.fla-excerpt {
  font-size: 1rem;
  color: #444;
  line-height: 1.5;
}

/* Responsive Design */
@media (max-width: 700px) {
  .fla-row, .fla-row a {
    flex-direction: column;
  }

  .fla-thumb {
    flex: none;
    width: 100%;
    height: auto;
  }

  .fla-thumb img {
    height: auto;
  }

  .fla-info {
    padding: 1rem;
  }

  .fla-title {
    font-size: 1.2rem;
  }
}
</style>
