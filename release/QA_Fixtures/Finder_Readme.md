<h1 align="center">Glancemark Finder check</h1>

> [!TIP]
> This should render as a callout. Open the section below and follow the footnote.[^note]

| Feature | Count | State |
| :--- | ---: | :---: |
| Aligned columns | 3 | Ready |
| Code span | 1 | `# native` |

<details>
<summary>Expand this section</summary>

Bold text spans **this inline equation $x^2+y^2$ and its result**.

</details>

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

```mermaid
flowchart LR
  A[Markdown] --> B[Finder Quick Look]
```

```geojson
{"type":"Feature","properties":{"name":"Sample park"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[4,0],[4,3],[0,3],[0,0]]]}}
```

```topojson
{"type":"Topology","transform":{"scale":[1,1],"translate":[0,0]},"objects":{"trail":{"type":"LineString","arcs":[0]}},"arcs":[[[0,0],[3,0],[0,2]]]}
```

```stl
solid Triangle
  facet normal 0 0 1
    outer loop
      vertex 0 0 0
      vertex 2 0 0
      vertex 0 2 0
    endloop
  endfacet
endsolid Triangle
```

[^note]: Use the backlink to return to the callout.
