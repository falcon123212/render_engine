# Bench CUDA : cache a dependances contre les baselines


## Scene principale

| Scenario | SHaRC N=64 resp=8, 1.57x | Accumulation+parlampe N=32, 1.53x | SHaRC + memoire naive, 1.57x | Accum+parlampe + memoire naive N=32, 1.53x | Accum+parlampe + memoire naive N=64, 1.53x | SHaRC + memoire + instantanes, 1.57x | Accum + memoire + instantanes N=32, 1.53x | Accum + memoire + instantanes N=64, 1.53x | Oracle | v3 | v4-A memoire | v4-C rampe | v4-AC memoire+rampe | v4-A2 memoire verifiee | v4-A2C memoire verifiee+rampe | v5-A instantanes verifies | v5-A instantanes | v5-AB instantanes+projection |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| R1 allumee-eteinte-rallumee | 40.6 % | 66.0 % | 20.5 % | 10.1 % | 7.0 % | 20.5 % | 10.1 % | 7.0 % | 30.7 % | 36.4 % | 6.7 % | 35.1 % | 6.7 % | 6.7 % | 6.7 % | 10.0 % | 6.6 % | 6.6 % |
| R2 allumee-eteinte-porte-rallumee | 43.7 % | 70.4 % | 21.0 % | 13.1 % | 12.6 % | 21.0 % | 13.1 % | 12.6 % | 32.2 % | 37.8 % | 38.8 % | 36.0 % | 37.8 % | 12.4 % | 12.4 % | 12.4 % | 12.4 % | 13.3 % |
| R3 porte ouverte-fermee-rouverte | 20.8 % | 11.2 % | 20.8 % | 11.2 % | 8.0 % | 20.5 % | 10.1 % | 7.0 % | 9.3 % | 11.8 % | 11.8 % | 11.8 % | 11.8 % | 11.8 % | 11.8 % | 10.0 % | 6.6 % | 6.6 % |
| I1 lampe eteinte | 5.5 % | 8.0 % | 5.5 % | 8.0 % | 5.5 % | 5.5 % | 8.0 % | 5.5 % | 73.1 % | 5.2 % | 5.2 % | 5.2 % | 5.2 % | 5.2 % | 5.2 % | 5.2 % | 5.2 % | 5.2 % |
| I2 porte | 12.0 % | 12.0 % | 12.0 % | 12.0 % | 12.0 % | 12.0 % | 12.0 % | 12.0 % | 8.1 % | 10.7 % | 10.7 % | 10.7 % | 10.7 % | 10.7 % | 10.7 % | 10.7 % | 10.7 % | 10.7 % |
| I3 lampe allumee 1re fois | 42.4 % | 69.3 % | 42.4 % | 69.3 % | 77.6 % | 42.4 % | 69.3 % | 77.6 % | 36.7 % | 36.6 % | 36.6 % | 33.5 % | 33.5 % | 36.6 % | 33.5 % | 33.5 % | 33.5 % | 33.5 % |
| I4 boite | 20.2 % | 10.1 % | 20.2 % | 10.1 % | 7.3 % | 20.2 % | 10.1 % | 7.3 % | 6.5 % | 6.8 % | 6.8 % | 6.8 % | 6.8 % | 6.8 % | 6.8 % | 6.8 % | 6.8 % | 6.8 % |

| Methode | G vs baselines publiees | Verdict | G vs baselines + memoire/instantanes | Verdict |
|---|---|---|---|---|
| v3 | 1.14 | equivalent | 0.66 | regression |
| v4-A2C memoire verifiee+rampe | 1.72 | gain net | 1.00 | equivalent |
| v5-A instantanes | 1.88 | gain net | 1.09 | equivalent |
| v5-A instantanes verifies | 1.66 | gain net | 0.97 | equivalent |
| v5-AB instantanes+projection | 1.86 | gain net | 1.08 | equivalent |
| Oracle | 0.89 | equivalent | 0.52 | regression |

## Scene de validation (jamais vue pendant la mise au point)

| Scenario | SHaRC N=64 resp=8, 1.57x | Accumulation+parlampe N=32, 1.53x | SHaRC + memoire naive, 1.57x | Accum+parlampe + memoire naive N=32, 1.53x | Accum+parlampe + memoire naive N=64, 1.53x | SHaRC + memoire + instantanes, 1.57x | Accum + memoire + instantanes N=32, 1.53x | Accum + memoire + instantanes N=64, 1.53x | Oracle | v3 | v4-A memoire | v4-C rampe | v4-AC memoire+rampe | v4-A2 memoire verifiee | v4-A2C memoire verifiee+rampe | v5-A instantanes verifies | v5-A instantanes | v5-AB instantanes+projection |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| R1 allumee-eteinte-rallumee | 45.3 % | 72.9 % | 24.2 % | 11.7 % | 8.1 % | 24.2 % | 11.6 % | 8.0 % | 35.5 % | 40.7 % | 7.6 % | 39.5 % | 7.6 % | 7.6 % | 7.6 % | 12.0 % | 7.5 % | 7.5 % |
| R2 allumee-eteinte-porte-rallumee | 48.3 % | 78.1 % | 24.6 % | 15.9 % | 15.1 % | 24.6 % | 15.9 % | 15.1 % | 36.5 % | 42.8 % | 43.8 % | 41.0 % | 42.7 % | 15.4 % | 15.4 % | 15.4 % | 15.4 % | 16.1 % |
| R3 porte ouverte-fermee-rouverte | 24.8 % | 12.9 % | 24.8 % | 12.9 % | 9.3 % | 24.2 % | 11.6 % | 8.0 % | 11.0 % | 14.0 % | 14.0 % | 14.0 % | 14.0 % | 14.0 % | 14.0 % | 12.0 % | 7.5 % | 7.5 % |
| I1 lampe eteinte | 6.3 % | 9.2 % | 6.3 % | 9.2 % | 6.3 % | 6.3 % | 9.2 % | 6.3 % | 91.8 % | 6.0 % | 6.0 % | 6.0 % | 6.0 % | 6.0 % | 6.0 % | 6.0 % | 6.0 % | 6.0 % |
| I2 porte | 13.5 % | 13.0 % | 13.5 % | 13.0 % | 13.6 % | 13.5 % | 13.0 % | 13.6 % | 8.9 % | 12.4 % | 12.4 % | 12.4 % | 12.4 % | 12.4 % | 12.4 % | 12.4 % | 12.4 % | 12.4 % |
| I3 lampe allumee 1re fois | 48.2 % | 77.9 % | 48.2 % | 77.9 % | 87.4 % | 48.2 % | 77.9 % | 87.4 % | 41.2 % | 41.2 % | 41.2 % | 37.6 % | 37.6 % | 41.2 % | 37.6 % | 37.6 % | 37.6 % | 37.6 % |
| I4 boite | 23.8 % | 11.6 % | 23.8 % | 11.6 % | 8.3 % | 23.8 % | 11.6 % | 8.3 % | 7.5 % | 7.8 % | 7.8 % | 7.8 % | 7.8 % | 7.8 % | 7.8 % | 7.8 % | 7.8 % | 7.8 % |

| Methode | G vs baselines publiees | Verdict | G vs baselines + memoire/instantanes | Verdict |
|---|---|---|---|---|
| v3 | 1.12 | equivalent | 0.66 | regression |
| v4-A2C memoire verifiee+rampe | 1.68 | gain net | 0.99 | equivalent |
| v5-A instantanes | 1.83 | gain net | 1.08 | equivalent |
| v5-A instantanes verifies | 1.60 | gain net | 0.94 | equivalent |
| v5-AB instantanes+projection | 1.82 | gain net | 1.07 | equivalent |
| Oracle | 0.87 | regression | 0.51 | regression |

## Scene stress (8 lampes, mur mobile, boites)

| Scenario | SHaRC N=64 resp=8, 1.57x | SHaRC + memoire naive, 1.57x | Accumulation+parlampe N=32, 1.53x | Accum+parlampe + memoire naive N=32, 1.53x | Accum+parlampe + memoire naive N=64, 1.53x | SHaRC + memoire + instantanes, 1.57x | Accum + memoire + instantanes N=32, 1.53x | Accum + memoire + instantanes N=64, 1.53x | Oracle | v3 | v4-A2C memoire verifiee+rampe | v5-A instantanes verifies | v5-A instantanes | v5-AB instantanes+projection |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| G1 mur effondre | 17.9 % | 17.9 % | 13.8 % | 13.8 % | 15.9 % | 17.9 % | 13.8 % | 15.9 % | 7.1 % | 9.9 % | 9.9 % | 9.9 % | 9.9 % | 9.9 % |
| G2 mur effondre puis reconstruit | 17.1 % | 17.1 % | 11.8 % | 11.8 % | 9.4 % | 16.1 % | 7.8 % | 5.4 % | 6.4 % | 10.0 % | 10.0 % | 7.5 % | 5.1 % | 5.1 % |
| G3 quatre objets deplaces | 17.6 % | 17.6 % | 15.6 % | 15.6 % | 18.1 % | 17.6 % | 15.6 % | 18.1 % | 8.0 % | 11.7 % | 11.7 % | 11.7 % | 11.7 % | 11.7 % |
| G4 objets aller-retour | 17.2 % | 17.2 % | 12.2 % | 12.2 % | 9.9 % | 16.1 % | 7.8 % | 5.4 % | 7.1 % | 10.6 % | 10.6 % | 7.5 % | 5.1 % | 5.1 % |
| L1 quatre lampes eteintes | 11.0 % | 11.0 % | 16.0 % | 16.0 % | 11.0 % | 11.0 % | 16.0 % | 11.0 % | 259.1 % | 10.5 % | 10.5 % | 10.5 % | 10.5 % | 10.5 % |
| L2 quatre lampes eteintes puis rallumees | 45.4 % | 16.1 % | 78.2 % | 7.9 % | 5.4 % | 16.1 % | 7.8 % | 5.4 % | 31.8 % | 39.2 % | 5.1 % | 7.5 % | 5.1 % | 5.1 % |
| L3 trois lampes allumees 1re fois | 18.1 % | 18.1 % | 23.3 % | 23.3 % | 25.6 % | 18.1 % | 23.3 % | 25.6 % | 18.2 % | 19.0 % | 18.8 % | 18.8 % | 18.8 % | 18.8 % |
| M1 extinction, mur effondre dans le noir, rallumage | 46.6 % | 17.4 % | 79.5 % | 12.8 % | 14.8 % | 17.4 % | 12.8 % | 14.8 % | 35.7 % | 39.3 % | 9.9 % | 9.9 % | 9.9 % | 10.6 % |

| Methode | G vs baselines publiees | Verdict | G vs baselines + memoire/instantanes | Verdict |
|---|---|---|---|---|
| v3 | 1.17 | gain net | 0.62 | regression |
| v4-A2C memoire verifiee+rampe | 1.79 | gain net | 0.96 | equivalent |
| v5-A instantanes | 2.14 | rupture | 1.14 | equivalent |
| v5-A instantanes verifies | 1.85 | gain net | 0.99 | equivalent |
| v5-AB instantanes+projection | 2.12 | rupture | 1.13 | equivalent |
| Oracle | 0.99 | equivalent | 0.53 | regression |
